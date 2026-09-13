# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Webhooks
    # Notices an endpoint that has been failing for days and disables it.
    #
    # A run of failures starts at the first failure after a success and ends at the next
    # success. If a run has lasted DISABLE_AFTER, the endpoint is disabled, its pending
    # deliveries are failed, and a `webhook_endpoint.disabled` event goes to the
    # merchant, which reaches their other endpoints. A quiet spell longer than
    # RUN_BREAK (no attempts at all) also ends a run, so an endpoint that failed once a
    # week ago and once today has not been "failing for a week".
    #
    # Why five days: the retry window is three, so a single event can never disable an
    # endpoint on its own. It takes steady traffic failing for longer than any one
    # delivery is retried, which is what "the merchant's endpoint is down, not having a
    # bad afternoon" looks like. Stripe's webhook docs give the three-day retry window
    # but no disabling threshold, so five days is my choice, not theirs.
    module EndpointHealth
      extend T::Sig

      DISABLE_AFTER = T.let(5 * Clock::SECONDS_PER_DAY, Integer)
      RUN_BREAK = T.let(Clock::SECONDS_PER_DAY, Integer)
      REASON = 'failing_continuously'

      # Clears the run. Writes nothing when there is no run, which is the common case,
      # so a healthy endpoint's row is not updated on every delivery.
      sig { params(db: Sequel::Database, endpoint_id: String).void }
      def self.success(db, endpoint_id)
        db[:webhook_endpoints].where(id: endpoint_id).exclude(failing_since: nil)
                              .update(failing_since: nil, last_failure_at: nil)
      end

      # Extends or starts the run, and disables the endpoint if it has gone on long
      # enough. Returns :disabled if this call disabled it, otherwise :failing. Runs
      # inside the caller's transaction so the disable, the failed deliveries and the
      # event commit together.
      sig { params(db: Sequel::Database, endpoint_id: String, clock: Clock).returns(Symbol) }
      def self.failure(db, endpoint_id, clock:)
        now = clock.now
        row = db.fetch(<<~SQL, id: endpoint_id, now: now, run_break: now - RUN_BREAK).first
          UPDATE webhook_endpoints SET
            failing_since = CASE
              WHEN failing_since IS NULL OR last_failure_at < :run_break THEN :now
              ELSE failing_since
            END,
            last_failure_at = GREATEST(last_failure_at, :now)
          WHERE id = :id
          RETURNING *
        SQL
        return :failing unless row && row[:status] == 'enabled' && row[:deleted_at].nil?
        return :failing if now - row[:failing_since] < DISABLE_AFTER

        disable!(db, row, clock)
        :disabled
      end

      sig { params(db: Sequel::Database, row: T::Hash[Symbol, T.untyped], clock: Clock).void }
      def self.disable!(db, row, clock)
        now = clock.now
        updated = db[:webhook_endpoints].where(id: row[:id], status: 'enabled').returning
                                        .update(status: 'disabled', disabled_reason: REASON, updated_at: now).first
        return unless updated

        Deliveries.fail_pending!(db, endpoint_id: row[:id], now: now, reason: 'endpoint_disabled')
        Clearinghouse::Events.emit!(db, merchant_id: row[:merchant_id], type: 'webhook_endpoint.disabled',
                                        object: Endpoints.from_row(updated).to_api, clock: clock)
      end
    end
  end
end
