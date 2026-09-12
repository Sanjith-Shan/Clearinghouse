# typed: false
# frozen_string_literal: true

# The isolated claim in one round trip. The first version ran it from Ruby: a candidate
# query, then per endpoint BEGIN, lock, count, lease, COMMIT. At about 3 ms per round
# trip to Postgres in Docker on this laptop, that capped claims at 62 to 83 a second
# across 32 threads, against 245 to 386 for the one-statement FIFO claim
# (exp/webhooks/claim_bench.rb), and experiment 6 showed isolation losing to FIFO
# on an all-healthy workload because of it.
#
# The rules are unchanged; they have moved here:
# - candidates: endpoints with due, unleased deliveries, not open (or open with the
#   cool-down over) and under their cap, oldest due delivery first;
# - for each: lock the endpoint row FOR UPDATE SKIP LOCKED (skip it if another claimer
#   has it), then count its live leases in a fresh statement, then lease one delivery;
# - the cap is max_in_flight when closed and 1 when half-open; an open endpoint whose
#   cool-down is over becomes half-open when its probe is leased.
#
# In PL/pgSQL each statement of a VOLATILE function takes a new snapshot under READ
# COMMITTED, so the count still sees every lease committed before the lock was taken,
# which is what makes the cap hold. The one difference: endpoint rows locked and then
# skipped stay locked until this claim's transaction ends, milliseconds later, where
# before each was released at once. Other claimers skip them meanwhile.
Sequel.migration do
  up do
    run <<~SQL
      CREATE FUNCTION webhook_claim_isolated(
        p_now timestamptz, p_lease_seconds double precision, p_token text,
        p_max_in_flight integer, p_candidates integer
      ) RETURNS SETOF webhook_deliveries
      LANGUAGE plpgsql VOLATILE AS $$
      DECLARE
        candidate record;
        endpoint record;
        in_flight bigint;
        claimed webhook_deliveries;
      BEGIN
        FOR candidate IN
          WITH due AS (
            SELECT d.endpoint_id, min(d.next_attempt_at) AS due_at
            FROM webhook_deliveries d
            WHERE d.status = 'pending' AND d.next_attempt_at <= p_now
              AND (d.lease_expires_at IS NULL OR d.lease_expires_at <= p_now)
            GROUP BY d.endpoint_id
          )
          SELECT due.endpoint_id
          FROM due
          JOIN webhook_endpoints e ON e.id = due.endpoint_id
          WHERE e.status = 'enabled' AND e.deleted_at IS NULL
            AND (e.breaker_state <> 'open' OR e.breaker_retry_at <= p_now)
            AND (
              SELECT count(*) FROM webhook_deliveries l
              WHERE l.endpoint_id = due.endpoint_id AND l.status = 'pending'
                AND l.lease_token IS NOT NULL AND l.lease_expires_at > p_now
            ) < CASE WHEN e.breaker_state = 'closed' THEN p_max_in_flight ELSE 1 END
          ORDER BY due.due_at
          LIMIT p_candidates
        LOOP
          SELECT e.id, e.breaker_state, e.breaker_retry_at INTO endpoint
          FROM webhook_endpoints e
          WHERE e.id = candidate.endpoint_id AND e.status = 'enabled' AND e.deleted_at IS NULL
          FOR UPDATE SKIP LOCKED;
          CONTINUE WHEN NOT FOUND;
          CONTINUE WHEN endpoint.breaker_state = 'open' AND endpoint.breaker_retry_at > p_now;

          SELECT count(*) INTO in_flight
          FROM webhook_deliveries l
          WHERE l.endpoint_id = endpoint.id AND l.status = 'pending'
            AND l.lease_token IS NOT NULL AND l.lease_expires_at > p_now;
          CONTINUE WHEN in_flight >= CASE WHEN endpoint.breaker_state = 'closed' THEN p_max_in_flight ELSE 1 END;

          UPDATE webhook_deliveries d SET
            lease_token = p_token,
            lease_expires_at = p_now + make_interval(secs => p_lease_seconds),
            attempts = d.attempts + 1,
            last_attempt_at = p_now
          WHERE d.id = (
            SELECT n.id FROM webhook_deliveries n
            WHERE n.endpoint_id = endpoint.id AND n.status = 'pending' AND n.next_attempt_at <= p_now
              AND (n.lease_expires_at IS NULL OR n.lease_expires_at <= p_now)
            ORDER BY n.next_attempt_at, n.id
            LIMIT 1
            FOR UPDATE SKIP LOCKED
          )
          RETURNING d.* INTO claimed;
          CONTINUE WHEN NOT FOUND;

          IF endpoint.breaker_state = 'open' THEN
            UPDATE webhook_endpoints SET breaker_state = 'half_open', breaker_retry_at = NULL
            WHERE id = endpoint.id;
          END IF;
          RETURN NEXT claimed;
          RETURN;
        END LOOP;
      END
      $$;
    SQL
    run 'GRANT EXECUTE ON FUNCTION webhook_claim_isolated(timestamptz, double precision, text, integer, integer) ' \
        'TO clearinghouse_app'
  end

  down do
    run 'DROP FUNCTION webhook_claim_isolated(timestamptz, double precision, text, integer, integer)'
  end
end
