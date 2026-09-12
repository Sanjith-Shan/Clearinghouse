# typed: false
# frozen_string_literal: true

# Webhook endpoints: where a merchant wants events sent, which ones, at which API
# version, and the secrets deliveries are signed with.
#
# The signing secrets are stored as they are. They cannot be hashed like API keys,
# because signing needs the secret itself, not a way to recognise it. A real system
# would encrypt these columns with a key from a KMS (envelope encryption, a data key
# per row or per merchant) and decrypt only inside the delivery worker. Clearinghouse
# is a simulation and keeps them in plaintext; docs/design/webhooks.md says so.
#
# Deleting an endpoint sets deleted_at rather than removing the row, so the delivery
# history that references it survives. The app role therefore needs UPDATE but never
# DELETE.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE webhook_endpoints (
        id                         text PRIMARY KEY CHECK (id ~ '^we_[A-Za-z0-9]{24}$'),
        merchant_id                text NOT NULL REFERENCES merchants (id),
        url                        text NOT NULL CHECK (length(url) BETWEEN 1 AND 2048),
        enabled_events             jsonb NOT NULL
                                     CHECK (jsonb_typeof(enabled_events) = 'array' AND jsonb_array_length(enabled_events) > 0),
        api_version                text NOT NULL CHECK (api_version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
        description                text CHECK (length(description) <= 500),
        status                     text NOT NULL DEFAULT 'enabled' CHECK (status IN ('enabled', 'disabled')),
        disabled_reason            text,
        secret                     text NOT NULL CHECK (secret LIKE 'whsec\\_%'),
        previous_secret            text CHECK (previous_secret LIKE 'whsec\\_%'),
        previous_secret_expires_at timestamptz,
        created_at                 timestamptz NOT NULL,
        updated_at                 timestamptz NOT NULL,
        deleted_at                 timestamptz,
        CHECK ((status = 'disabled') = (disabled_reason IS NOT NULL)),
        CHECK ((previous_secret IS NULL) = (previous_secret_expires_at IS NULL)),
        CHECK (previous_secret IS DISTINCT FROM secret)
      );
      CREATE INDEX webhook_endpoints_merchant ON webhook_endpoints (merchant_id, created_at DESC, id DESC)
        WHERE deleted_at IS NULL;
    SQL
    run 'GRANT SELECT, INSERT, UPDATE ON webhook_endpoints TO clearinghouse_app'
  end

  down do
    drop_table(:webhook_endpoints)
  end
end
