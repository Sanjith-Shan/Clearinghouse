# typed: false
# frozen_string_literal: true

# The transactional outbox. An event row is written in the same database
# transaction as the state change it describes, so an event exists if and only if
# the change committed. Webhook delivery reads from here.
#
# - data is the object at the LATEST API version. Delivery renders it at each
#   endpoint's version, so nothing version-specific is stored. It is `json`, not
#   `jsonb`: jsonb reorders keys (shortest first), and a webhook payload should
#   read in the same key order as the API response for the same object.
# - created_at comes from the injected clock (simulated time), never now().
# - seq orders events for the dispatcher. It is a sequence value, so it is
#   assigned at insert, not commit: a dispatcher that scans by seq must allow for a
#   lower seq committing after a higher one it has already seen.
#
# Events are history. The app role may insert and read them, nothing else.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE events (
        id              text PRIMARY KEY CHECK (id ~ '^evt_[A-Za-z0-9]{24}$'),
        seq             bigserial NOT NULL UNIQUE,
        merchant_id     text NOT NULL REFERENCES merchants (id),
        type            text NOT NULL CHECK (type ~ '^[a-z_]+(\\.[a-z_]+)+$'),
        -- The id of data's object, so "every event for this payment" is an index scan.
        object_id       text NOT NULL,
        data            json NOT NULL CHECK (json_typeof(data) = 'object'),
        -- The API request that caused the event, when there was one (Stripe's
        -- event.request). Null for events from workers such as the expiry sweep.
        request_id      text,
        idempotency_key text,
        created_at      timestamptz NOT NULL
      );
      CREATE INDEX events_merchant_seq ON events (merchant_id, seq);
      CREATE INDEX events_object_id ON events (object_id);
    SQL
    run 'GRANT SELECT, INSERT ON events TO clearinghouse_app'
  end

  down do
    drop_table(:events)
  end
end
