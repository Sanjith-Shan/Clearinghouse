# typed: false
# frozen_string_literal: true

# Per-endpoint isolation: a circuit breaker persisted on the endpoint row, so every
# worker in every process sees the same state, and an index for counting an
# endpoint's in-flight deliveries (pending rows holding a lease) when claiming.
Sequel.migration do
  up do
    run <<~SQL
      ALTER TABLE webhook_endpoints
        ADD COLUMN breaker_state text NOT NULL DEFAULT 'closed'
          CHECK (breaker_state IN ('closed', 'open', 'half_open')),
        ADD COLUMN consecutive_failures integer NOT NULL DEFAULT 0 CHECK (consecutive_failures >= 0),
        ADD COLUMN breaker_reopens integer NOT NULL DEFAULT 0 CHECK (breaker_reopens >= 0),
        ADD COLUMN breaker_retry_at timestamptz,
        ADD CONSTRAINT webhook_endpoints_open_breaker_has_retry
          CHECK (breaker_state <> 'open' OR breaker_retry_at IS NOT NULL);

      CREATE INDEX webhook_deliveries_in_flight ON webhook_deliveries (endpoint_id, lease_expires_at)
        WHERE status = 'pending' AND lease_token IS NOT NULL;
    SQL
  end

  down do
    run 'DROP INDEX webhook_deliveries_in_flight'
    run <<~SQL
      ALTER TABLE webhook_endpoints
        DROP CONSTRAINT webhook_endpoints_open_breaker_has_retry,
        DROP COLUMN breaker_state, DROP COLUMN consecutive_failures, DROP COLUMN breaker_reopens,
        DROP COLUMN breaker_retry_at
    SQL
  end
end
