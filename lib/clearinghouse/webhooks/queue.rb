# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Webhooks
    # A delivery a worker has claimed. The lease token is the worker's proof of
    # ownership when it records a failure; a worker whose lease expired and was taken
    # over finds its token gone and records nothing but a success.
    class Claim < T::Struct
      const :delivery_id, String
      const :event_id, String
      const :endpoint_id, String
      const :lease_token, String
      # Attempts so far, this one included. A claim counts as an attempt, so a
      # delivery that crashes its worker every time still runs out of retries.
      const :attempts, Integer
      const :retry_deadline_at, Time
    end

    # How workers pick the next delivery. Both implementations claim with
    # FOR UPDATE SKIP LOCKED and mark a lease in one short statement or transaction,
    # so the lock is held for milliseconds and the HTTP request happens with no
    # transaction open.
    module Queue
      extend T::Sig
      extend T::Helpers

      interface!

      sig { abstract.params(db: Sequel::Database, now: Time, lease_seconds: Numeric, token: String).returns(T.nilable(Claim)) }
      def claim(db, now:, lease_seconds:, token:); end

      # The breaker the worker should update after each attempt, or nil for none.
      sig { abstract.returns(T.nilable(CircuitBreaker)) }
      def breaker; end

      # Short name for logs and command lines.
      sig { abstract.returns(String) }
      def mode; end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(Claim) }
      def self.claim_from(row)
        Claim.new(delivery_id: row[:id], event_id: row[:event_id], endpoint_id: row[:endpoint_id],
                  lease_token: row[:lease_token], attempts: row[:attempts],
                  retry_deadline_at: row[:retry_deadline_at].utc)
      end

      # A pending delivery that is due and not held by a live lease.
      CLAIMABLE = <<~SQL
        d.status = 'pending'
        AND d.next_attempt_at <= :now
        AND (d.lease_expires_at IS NULL OR d.lease_expires_at <= :now)
      SQL

      # The lease columns a claim sets.
      LEASE = <<~SQL
        lease_token = :token,
        lease_expires_at = CAST(:now AS timestamptz) + make_interval(secs => :lease_seconds),
        attempts = d.attempts + 1,
        last_attempt_at = :now
      SQL
    end

    # One queue for everything, oldest event first, and nothing else: no per-endpoint
    # cap, no circuit breaker. This is the baseline experiment 6 measures against. It
    # is a real, correct queue (SKIP LOCKED, leases, the same retries); what it lacks is
    # any defence against an endpoint that holds a worker for the whole timeout.
    class FifoQueue
      extend T::Sig
      include Queue

      SQL = <<~SQL.freeze
        WITH next AS (
          SELECT d.id
          FROM webhook_deliveries d
          WHERE #{Queue::CLAIMABLE}
          ORDER BY d.event_created_at, d.id
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        UPDATE webhook_deliveries d SET #{Queue::LEASE}
        FROM next
        WHERE d.id = next.id
        RETURNING d.*
      SQL

      sig { override.params(db: Sequel::Database, now: Time, lease_seconds: Numeric, token: String).returns(T.nilable(Claim)) }
      def claim(db, now:, lease_seconds:, token:)
        row = db.fetch(SQL, now: now, lease_seconds: lease_seconds.to_f, token: token).first
        row ? Queue.claim_from(row) : nil
      end

      sig { override.returns(T.nilable(CircuitBreaker)) }
      def breaker = nil

      sig { override.returns(String) }
      def mode = 'fifo'
    end

    # Clearinghouse's queue: per-endpoint isolation.
    #
    # - **In-flight cap.** At most max_in_flight deliveries per endpoint hold a live
    #   lease at once (1 while its breaker is half-open). The cap is enforced in the
    #   claim itself: the claimer locks the endpoint row with FOR UPDATE SKIP LOCKED,
    #   counts that endpoint's live leases, and only then leases a delivery, all in one
    #   statement: a PL/pgSQL function, so a claim is one round trip to Postgres.
    #   Claims for one endpoint therefore take turns on its row
    #   lock, and each sees every lease committed before it, so the count cannot race,
    #   across threads or processes. Counting leases instead of keeping a counter
    #   means a worker killed mid-delivery cannot leak a slot: its lease expires and
    #   stops counting.
    # - **Circuit breaker**, persisted on the endpoint row (see CircuitBreaker). An open
    #   endpoint is not claimed at all.
    # - **Fair order.** Candidates are endpoints with due work, oldest due delivery
    #   first, skipping any that are open or at their cap. A worker never waits on an
    #   endpoint another worker is claiming for; SKIP LOCKED moves it to the next one.
    #
    # One hung endpoint therefore holds at most max_in_flight workers, and only until its
    # breaker opens.
    class IsolatedQueue
      extend T::Sig
      include Queue

      # One round trip: the claim runs inside Postgres, in webhook_claim_isolated (see
      # db/migrations/20260924140000_webhook_claim_function.rb for the steps).
      CLAIM_SQL = <<~SQL
        SELECT * FROM webhook_claim_isolated(:now, :lease_seconds, :token, :max_in_flight, :candidates)
      SQL

      sig { returns(Integer) }
      attr_reader :max_in_flight

      sig { override.returns(CircuitBreaker) }
      attr_reader :breaker

      sig { params(max_in_flight: Integer, breaker: CircuitBreaker, candidates: Integer).void }
      def initialize(max_in_flight: 4, breaker: CircuitBreaker.new, candidates: 16)
        raise ArgumentError, 'max_in_flight must be at least 1' if max_in_flight < 1

        @max_in_flight = max_in_flight
        @breaker = breaker
        @candidates = candidates
      end

      sig { override.returns(String) }
      def mode = 'isolated'

      sig { override.params(db: Sequel::Database, now: Time, lease_seconds: Numeric, token: String).returns(T.nilable(Claim)) }
      def claim(db, now:, lease_seconds:, token:)
        row = db.fetch(CLAIM_SQL, now: now, lease_seconds: lease_seconds.to_f, token: token,
                                  max_in_flight: @max_in_flight, candidates: @candidates).first
        row ? Queue.claim_from(row) : nil
      end
    end
  end
end
