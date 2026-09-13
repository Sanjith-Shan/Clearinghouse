# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Webhooks
    # Reads and writes an endpoint's circuit breaker on its webhook_endpoints row.
    # Every change happens under that row's lock, taken either by the claim (FOR UPDATE
    # SKIP LOCKED) or by the record (FOR UPDATE), so two workers never apply
    # transitions to the same breaker from stale reads.
    module Breakers
      extend T::Sig

      # A transition worth logging: from one state to another.
      class Transition < T::Struct
        const :endpoint_id, String
        const :from, String
        const :to, String
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(CircuitBreaker::State) }
      def self.state_of(row)
        CircuitBreaker::State.new(state: row[:breaker_state], consecutive_failures: row[:consecutive_failures],
                                  reopens: row[:breaker_reopens], retry_at: row[:breaker_retry_at]&.utc)
      end

      sig { params(db: Sequel::Database, endpoint_id: String, state: CircuitBreaker::State).void }
      def self.store(db, endpoint_id, state)
        db[:webhook_endpoints].where(id: endpoint_id).update(
          breaker_state: state.state, consecutive_failures: state.consecutive_failures,
          breaker_reopens: state.reopens, breaker_retry_at: state.retry_at
        )
      end

      # Closes the breaker. The WHERE clause makes this a no-op, with no row write,
      # for an endpoint that is already closed with no failures, which is almost always.
      sig { params(db: Sequel::Database, endpoint_id: String).returns(T.nilable(Transition)) }
      def self.success(db, endpoint_id)
        row = db[:webhook_endpoints].where(id: endpoint_id)
                                    .where(Sequel.lit("breaker_state <> 'closed' OR consecutive_failures > 0"))
                                    .for_update.first
        return nil unless row

        store(db, endpoint_id, CircuitBreaker::State::CLOSED)
        transition(endpoint_id, row[:breaker_state], 'closed')
      end

      sig do
        params(db: Sequel::Database, endpoint_id: String, breaker: CircuitBreaker, now: Time)
          .returns(T.nilable(Transition))
      end
      def self.failure(db, endpoint_id, breaker, now:)
        row = db[:webhook_endpoints].where(id: endpoint_id).for_update.first
        return nil unless row

        before = state_of(row)
        after = breaker.after_failure(before, now: now)
        store(db, endpoint_id, after)
        transition(endpoint_id, before.state, after.state)
      end

      sig { params(endpoint_id: String, from: String, to: String).returns(T.nilable(Transition)) }
      def self.transition(endpoint_id, from, to)
        from == to ? nil : Transition.new(endpoint_id: endpoint_id, from: from, to: to)
      end
    end
  end
end
