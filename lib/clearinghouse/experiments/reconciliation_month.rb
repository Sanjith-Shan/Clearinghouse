# typed: true
# frozen_string_literal: true

require 'date'
require 'json'
require 'securerandom'
require_relative '../../../sim/lib/acquirer_sim'
require_relative 'local_server'
require_relative 'reconciliation_month/drivers'
require_relative 'reconciliation_month/scorer'
require_relative 'reconciliation_month/runner'

module Clearinghouse
  module Experiments
    # Experiment 5: a simulated month of payments, refunds, disputes and payouts, with
    # K discrepancies of the six types injected into the acquirer's settlement files,
    # scored against the simulator's ground truth. Run it with bin/exp-reconciliation.
    # Not loaded by lib/clearinghouse.rb.
    module ReconciliationMonth
      extend T::Sig

      # The knobs. Defaults are the published run's.
      class Config < T::Struct
        const :seed, Integer, default: 1
        const :payments, Integer, default: 1_500
        const :discrepancies, Integer, default: 60
        const :merchants, Integer, default: 3
        const :days, Integer, default: 30
        # Quiet days after the traffic, so disputes opened late in the month (seven
        # days after capture), their rulings and the last settlement lines all finish.
        const :tail_days, Integer, default: 14
        const :start, Date, default: Date.new(2026, 1, 1)
        const :refund_rate, Float, default: 0.15
        const :dispute_rate, Float, default: 0.03
        const :decline_rate, Float, default: 0.02
        const :accept_rate, Float, default: 0.25
        # Every this many days, one payment is made with a clock two days behind.
        const :lagging_every_days, Integer, default: 3
      end

      # The second API the lagging payments go through, and its clock.
      class Lagging < T::Struct
        const :clock, Clock::Test
        const :driver, Driver
      end

      # Everything a run needs, started in this process: the acquirer simulator, the
      # API on the experiment's clock, and a second API on a lagging clock. `run`
      # runs the month; `stop` shuts the servers down.
      class Harness
        extend T::Sig

        sig { params(db: Sequel::Database, config: Config).void }
        def initialize(db:, config:)
          @db = db
          @config = config
          start = Time.utc(config.start.year, config.start.month, config.start.day)
          @clock = T.let(Clock::Test.new(start: start), Clock::Test)
          simulator = AcquirerSim::Simulator.new
          simulator.configure('seed' => config.seed)
          @sim = T.let(LocalServer.new(AcquirerSim::App.new(simulator: simulator)), LocalServer)
          @acquirer = T.let(Acquirer::Client.new(clock: @clock, base_url: @sim.url, read_timeout: 30), Acquirer::Client)
          @admin_token = T.let(SecureRandom.hex(16), String)
          @api, @driver = api(@clock)
          lagging_clock = Clock::Test.new(start: start)
          @lagging_api, lagging_driver = api(lagging_clock)
          @lagging = T.let(Lagging.new(clock: lagging_clock, driver: lagging_driver), Lagging)
        end

        sig { returns(T::Hash[String, T.untyped]) }
        def run
          Runner.new(config: @config, db: @db, clock: @clock, sim_url: @sim.url, driver: @driver,
                     acquirer: @acquirer, lagging: @lagging).run
        end

        sig { void }
        def stop
          [@api, @lagging_api, @sim].each(&:stop)
        end

        private

        sig { params(clock: Clock).returns([LocalServer, ApiDriver]) }
        def api(clock)
          acquirer = Acquirer::Client.new(clock: clock, base_url: @sim.url, read_timeout: 30)
          deps = Api::Dependencies.new(db: @db, clock: clock, acquirer: acquirer, admin_token: @admin_token)
          server = LocalServer.new(Api.rack_app(deps))
          [server, ApiDriver.new(api_url: server.url, admin_token: @admin_token)]
        end
      end

      # Empties every table in the experiment's database, as the owner role, the way
      # the spec helper does. Refuses any database whose name does not say it is
      # for tests or experiments.
      sig { params(owner: Sequel::Database).void }
      def self.reset!(owner)
        name = owner.opts[:database].to_s
        raise ArgumentError, "refusing to empty #{name}: not a test or experiment database" unless
          name.match?(/test|exp/)

        tables = owner.fetch("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map(:tablename) -
                 ['schema_migrations']
        owner.transaction do
          owner.run('SET LOCAL session_replication_role = replica')
          owner.run("TRUNCATE #{tables.map { |t| owner.literal(Sequel.identifier(t)) }.join(', ')} RESTART IDENTITY")
        end
      end
    end
  end
end
