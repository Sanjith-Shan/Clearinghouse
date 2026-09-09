# typed: false
# frozen_string_literal: true

# Webhook delivery: one row per event per subscribed endpoint, the dispatcher's cursor
# over the events outbox, and what the endpoint table needs to notice an endpoint
# that has been failing for days.
#
# The deliveries table is the queue. A worker claims a due row with
# FOR UPDATE SKIP LOCKED and marks it with a lease (token and expiry) in the same
# short statement, then sends the request with no transaction open, then records the
# outcome. A row is in flight while its lease is live; a worker that dies leaves a
# lease that expires, and the row becomes claimable again. See docs/design/webhooks.md.
#
# UNIQUE (event_id, endpoint_id) is what makes fan-out idempotent: the dispatcher can
# scan the same events twice and never create a second delivery.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE webhook_deliveries (
        id                text PRIMARY KEY CHECK (id ~ '^whd_[A-Za-z0-9]{24}$'),
        event_id          text NOT NULL REFERENCES events (id),
        endpoint_id       text NOT NULL REFERENCES webhook_endpoints (id),
        status            text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'succeeded', 'failed')),
        attempts          integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
        event_created_at  timestamptz NOT NULL,
        created_at        timestamptz NOT NULL,
        next_attempt_at   timestamptz NOT NULL,
        retry_deadline_at timestamptz NOT NULL,
        lease_token       text,
        lease_expires_at  timestamptz,
        last_attempt_at   timestamptz,
        last_status       integer,
        last_error        text,
        last_duration_ms  integer,
        succeeded_at      timestamptz,
        failed_at         timestamptz,
        UNIQUE (event_id, endpoint_id),
        CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
        CHECK (status = 'pending' OR lease_token IS NULL),
        CHECK (status <> 'succeeded' OR succeeded_at IS NOT NULL),
        CHECK (status <> 'failed' OR failed_at IS NOT NULL)
      );
      -- Claim order for the FIFO queue, and the due scan.
      CREATE INDEX webhook_deliveries_fifo ON webhook_deliveries (event_created_at, id) WHERE status = 'pending';
      CREATE INDEX webhook_deliveries_due ON webhook_deliveries (next_attempt_at) WHERE status = 'pending';
      CREATE INDEX webhook_deliveries_endpoint_pending ON webhook_deliveries (endpoint_id, next_attempt_at)
        WHERE status = 'pending';
      CREATE INDEX webhook_deliveries_deadline ON webhook_deliveries (retry_deadline_at) WHERE status = 'pending';
      CREATE INDEX webhook_deliveries_endpoint ON webhook_deliveries (endpoint_id, created_at);

      -- One row per dispatcher. cursor_seq: every event at or below it has been fanned
      -- out. barrier_seq/barrier_xmax: the next place the cursor may move to, once every
      -- transaction that was running when it was set has finished.
      CREATE TABLE webhook_dispatch_cursors (
        name         text PRIMARY KEY,
        cursor_seq   bigint NOT NULL DEFAULT 0,
        barrier_seq  bigint,
        barrier_xmax xid8,
        updated_at   timestamptz,
        CHECK ((barrier_seq IS NULL) = (barrier_xmax IS NULL)),
        CHECK (barrier_seq IS NULL OR barrier_seq > cursor_seq)
      );

      -- The current run of failures: when it started and the latest one. A success
      -- clears both.
      ALTER TABLE webhook_endpoints ADD COLUMN failing_since timestamptz, ADD COLUMN last_failure_at timestamptz;
    SQL
    run 'GRANT SELECT, INSERT, UPDATE ON webhook_deliveries TO clearinghouse_app'
    run 'GRANT SELECT, INSERT, UPDATE ON webhook_dispatch_cursors TO clearinghouse_app'
  end

  down do
    drop_table(:webhook_deliveries)
    drop_table(:webhook_dispatch_cursors)
    run 'ALTER TABLE webhook_endpoints DROP COLUMN failing_since, DROP COLUMN last_failure_at'
  end
end
