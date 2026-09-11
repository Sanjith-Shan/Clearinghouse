# typed: false
# frozen_string_literal: true

# Idempotency keys, after Brandur Leach's "Implementing Stripe-like Idempotency
# Keys in Postgres" (2017), with more on each row so that a key can be resumed by
# a process that never saw the original request:
#
# - flow and flow_input: which operation, with its parsed input, so the completer
#   can drive it without the HTTP request. flow_state carries what an earlier
#   phase created (a refund id) to the later ones.
# - recovery_point: the last atomic phase that committed. Each phase advances it
#   in the same transaction as its work.
# - locked_at and lock_token: a lease. A request that finds the lease expired takes
#   it with a new token, and every phase checks the token when it commits, so a
#   runner that stalled past its lease cannot commit over the one that replaced it.
# - response_*: the exact bytes, status and headers first sent, replayed on retry.
#   response_body is text, not json, because the replay must be byte for byte.
# - render_options: the API version and expand[] the response is rendered with.
#
# client_supplied is false for requests without an Idempotency-Key. They still get
# a row under a generated key, so a crash mid-flight can be recovered by the
# completer, but no client can ever replay them.
#
# The app role needs DELETE here, for the reaper. It is the one table where it
# does.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE idempotency_keys (
        id                  bigserial PRIMARY KEY,
        merchant_id         text NOT NULL REFERENCES merchants (id),
        key                 text NOT NULL CHECK (length(key) BETWEEN 1 AND 255),
        client_supplied     boolean NOT NULL,
        flow                text NOT NULL,
        flow_input          json NOT NULL,
        flow_state          json NOT NULL DEFAULT '{}'::json,
        request_method      text NOT NULL,
        request_path        text NOT NULL,
        request_fingerprint text NOT NULL CHECK (request_fingerprint ~ '^[0-9a-f]{64}$'),
        request_id          text NOT NULL,
        render_options      json NOT NULL,
        recovery_point      text NOT NULL,
        locked_at           timestamptz,
        lock_token          text,
        last_run_at         timestamptz NOT NULL,
        response_code       integer,
        response_body       text,
        response_headers    json,
        created_at          timestamptz NOT NULL,
        UNIQUE (merchant_id, key),
        CONSTRAINT idempotency_keys_finished_has_response
          CHECK ((recovery_point = 'finished') = (response_code IS NOT NULL AND response_body IS NOT NULL)),
        CONSTRAINT idempotency_keys_finished_unlocked CHECK (recovery_point <> 'finished' OR locked_at IS NULL),
        CONSTRAINT idempotency_keys_lease_whole CHECK ((locked_at IS NULL) = (lock_token IS NULL))
      );
      -- The completer's scan: unfinished keys, oldest run first.
      CREATE INDEX idempotency_keys_unfinished ON idempotency_keys (last_run_at) WHERE recovery_point <> 'finished';
      -- The reaper's scan.
      CREATE INDEX idempotency_keys_finished_created ON idempotency_keys (created_at) WHERE recovery_point = 'finished';

      -- Which unfinished request owns a PaymentIntent across its phases. Confirm,
      -- capture and cancel each span an acquirer call, and two of them must never
      -- interleave on one intent (a capture and a cancel both passing their checks,
      -- then one capturing and the other voiding).
      ALTER TABLE payment_intents ADD COLUMN locked_by bigint REFERENCES idempotency_keys (id) ON DELETE SET NULL;
    SQL
    run 'GRANT SELECT, INSERT, UPDATE, DELETE ON idempotency_keys TO clearinghouse_app'
  end

  down do
    alter_table(:payment_intents) { drop_column :locked_by }
    drop_table(:idempotency_keys)
  end
end
