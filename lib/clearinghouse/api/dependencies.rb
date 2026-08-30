# typed: true
# frozen_string_literal: true

require 'stringio'

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
      # The acquirer simulator client. Narrow this to the client's class once it exists.
      const :acquirer, T.nilable(Object), default: nil
      # Guards POST /v1/merchants. nil disables the endpoint.
      const :admin_token, T.nilable(String), default: nil
      # Where request logs go, one JSON object per line. nil keeps tests quiet.
      const :log, T.nilable(T.any(IO, StringIO)), default: nil

      sig { returns(Dependencies) }
      def self.from_env
        new(
          db: DB.connect(role: :app, max_connections: Integer(ENV.fetch('CLEARINGHOUSE_DB_POOL', '10'), 10)),
          clock: Clock::Real.new,
          admin_token: ENV.fetch('CLEARINGHOUSE_ADMIN_TOKEN', nil),
          log: $stdout
        )
      end
    end
  end
end
