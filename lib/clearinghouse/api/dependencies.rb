# typed: true
# frozen_string_literal: true

require 'stringio'
require_relative '../acquirer'

module Clearinghouse
  module Api
    # Everything the app talks to, passed in at construction so a test or an
    # experiment can wire a test clock, a separate database or a fake acquirer
    # without touching globals.
    #
    # Extension point: a new collaborator (the acquirer client, the RiskGate client,
    # a crash-injection hook) becomes a new prop here with a nil-safe default, and
    # `from_env` learns how to build the production one.
    class Dependencies < T::Struct
      extend T::Sig

      const :db, Sequel::Database
      const :clock, Clock
      # The acquirer. Specs pass a client for an in-process simulator, or a subclass
      # of the client that injects faults. nil only in apps that never move money.
      const :acquirer, T.nilable(Acquirer::Client), default: nil
      # How long an authorization can wait for capture before the expiry sweep
      # cancels it, in simulated days. Card networks allow about a week.
      const :authorization_ttl_days, Integer, default: 7
      # Guards POST /v1/merchants. nil disables the endpoint.
      const :admin_token, T.nilable(String), default: nil
      # Renders responses at the caller's version. Tests may pass an engine with
      # their own registry or loaders.
      const :versioning, Versioning::Engine, factory: -> { Versioning.engine }
      # Where request logs go, one JSON object per line. nil keeps tests quiet.
      const :log, T.nilable(T.any(IO, StringIO)), default: nil

      sig { returns(Dependencies) }
      def self.from_env
        clock = Clock::Real.new
        new(
          db: DB.connect(role: :app, max_connections: Integer(ENV.fetch('CLEARINGHOUSE_DB_POOL', '10'), 10)),
          clock: clock,
          acquirer: Acquirer::Client.new(clock: clock),
          admin_token: ENV.fetch('CLEARINGHOUSE_ADMIN_TOKEN', nil),
          log: $stdout
        )
      end
    end
  end
end
