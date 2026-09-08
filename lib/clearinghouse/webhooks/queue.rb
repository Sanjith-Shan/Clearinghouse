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
    end
  end
end
