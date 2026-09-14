# typed: true
# frozen_string_literal: true

require 'date'
require 'json'

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

require_relative 'local_server'
require_relative 'reconciliation_month/drivers'
require_relative 'reconciliation_month/payouts_stand_in'
require_relative 'reconciliation_month/scorer'
require_relative 'reconciliation_month/runner'
