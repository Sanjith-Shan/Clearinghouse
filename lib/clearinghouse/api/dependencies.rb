# typed: true
# frozen_string_literal: true

require 'stringio'
require_relative '../acquirer'
require_relative '../risk'
require_relative '../idempotency'

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
      # RiskGate, asked during every confirm. nil means no risk check at all (the
      # intent's `risk` stays null), which only specs and experiments that are not
      # about risk use; from_env always builds one.
      const :risk_client, T.nilable(Risk::Client), default: nil
      # How long a request's lease on its idempotency key lasts without a phase
      # committing. Longer than the slowest foreign call (acquirer read timeout
      # plus the risk deadline), or a slow request would be resumed by another
      # while it is still running.
      const :idempotency_lock_timeout, Numeric, default: Idempotency::Runner::DEFAULT_LOCK_TIMEOUT
      # Called at every recovery point. DISARMED except in crash experiments.
      const :crash_hook, Idempotency::CrashHook, factory: -> { Idempotency::CrashHook::DISARMED }
      # A Disputes::Service, for POST /v1/disputes/:id/close. Typed Object because api/
      # loads before disputes/. nil until the events outbox and the payment lookup it
      # needs are wired; the endpoint then answers 500 api_error and logs why.
      const :disputes, T.nilable(Object), default: nil
      # Guards POST /v1/merchants. nil disables the endpoint.
      const :admin_token, T.nilable(String), default: nil
      # Renders responses at the caller's version. Tests may pass an engine with
      # their own registry or loaders.
      const :versioning, Versioning::Engine, factory: -> { Versioning.engine }
      # Checks webhook endpoint URLs at registration (SafeHttp#pin). Tests pass one with a
      # fake resolver, or with test_mode to allow http://localhost.
      const :webhook_http, Webhooks::SafeHttp,
            factory: -> { Webhooks::SafeHttp.new(resolver: Webhooks::Egress::SystemResolver.new) }
      # Where request logs go, one JSON object per line. nil keeps tests quiet.
      const :log, T.nilable(T.any(IO, StringIO)), default: nil

      sig { returns(Dependencies) }
      def self.from_env
        clock = Clock::Real.new
        new(
          db: DB.connect(role: :app, max_connections: Integer(ENV.fetch('CLEARINGHOUSE_DB_POOL', '10'), 10)),
          clock: clock,
          acquirer: Acquirer::Client.new(clock: clock),
          risk_client: Risk.client,
          idempotency_lock_timeout: Float(ENV.fetch('CLEARINGHOUSE_IDEMPOTENCY_LOCK_TIMEOUT',
                                                    Idempotency::Runner::DEFAULT_LOCK_TIMEOUT.to_s)),
          # DISARMED unless CLEARINGHOUSE_ENV is test or experiment (CrashHook.from_env).
          crash_hook: Idempotency::CrashHook.from_env,
          admin_token: ENV.fetch('CLEARINGHOUSE_ADMIN_TOKEN', nil),
          webhook_http: Webhooks::SafeHttp.new(resolver: Webhooks::Egress::SystemResolver.new,
                                               test_mode: ENV['CLEARINGHOUSE_WEBHOOK_TEST_MODE'] == '1'),
          log: $stdout
        )
      end
    end
  end
end
