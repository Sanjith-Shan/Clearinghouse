# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Idempotency
    # Every atomic phase runs here: one SERIALIZABLE transaction, retried with
    # bounded, jittered backoff when Postgres reports a serialization failure or
    # a deadlock (Sequel raises SerializationFailure for both, SQLSTATE 40001 and
    # 40P01). Either means a concurrent transaction conflicted and this one was
    # rolled back whole, so running it again is safe and usually succeeds.
    #
    # Backoff is "full jitter": sleep a random time between zero and
    # min(max_delay, base_delay * 2^attempt). Retries from requests that
    # collided spread out instead of colliding again in lockstep.
    module Serializable
      extend T::Sig

      # How hard to try: attempts in total, and the backoff's base and cap in seconds.
      class Policy < T::Struct
        const :attempts, Integer, default: 8
        const :base_delay, Float, default: 0.005
        const :max_delay, Float, default: 0.25
      end

      # The conflict outlasted every attempt.
      class ExhaustedError < Clearinghouse::Error
        extend T::Sig

        sig { returns(Integer) }
        attr_reader :attempts

        sig { params(attempts: Integer, cause_message: String).void }
        def initialize(attempts, cause_message)
          super("serialization conflict persisted after #{attempts} attempts: #{cause_message}")
          @attempts = attempts
        end
      end

      Sleeper = T.type_alias { T.proc.params(seconds: Float).void }

      DEFAULT_SLEEPER = T.let(->(seconds) { sleep(seconds) }, Sleeper)

      # Retries counted across the process, for experiments. Only ever read.
      @retries = T.let(0, Integer)
      @mutex = T.let(Mutex.new, Mutex)

      class << self
        extend T::Sig

        sig { returns(Integer) }
        def retries
          @mutex.synchronize { @retries }
        end

        sig { void }
        def count_retry
          @mutex.synchronize { @retries += 1 }
        end
      end

      sig do
        type_parameters(:R)
          .params(db: Sequel::Database, policy: Policy, sleeper: Sleeper, random: Random,
                  block: T.proc.returns(T.type_parameter(:R)))
          .returns(T.type_parameter(:R))
      end
      def self.transaction(db, policy: Policy.new, sleeper: DEFAULT_SLEEPER, random: Random.new, &block) # rubocop:disable Style/ArgumentsForwarding
        # Nested inside another transaction, isolation would be ignored and a retry
        # would re-run only half of the work. Phases never nest.
        raise Clearinghouse::Error, 'a SERIALIZABLE phase cannot run inside another transaction' if db.in_transaction?

        attempt = 0
        begin
          attempt += 1
          db.transaction(isolation: :serializable, &block) # rubocop:disable Style/ArgumentsForwarding
        rescue Sequel::SerializationFailure => e
          raise ExhaustedError.new(attempt, e.message) if attempt >= policy.attempts

          count_retry
          sleeper.call(random.rand * [policy.max_delay, policy.base_delay * (2**attempt)].min.to_f)
          retry
        end
      end
    end
  end
end
