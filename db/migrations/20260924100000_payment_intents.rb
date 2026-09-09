# typed: false
# frozen_string_literal: true

# PaymentIntents. The state machine lives in Ruby as a transition table
# (lib/clearinghouse/payments/state_machine.rb); the checks here are the
# database's backstop for the amounts, which must hold in every state:
#
# - amount_capturable is only ever non-zero while an authorization is waiting to
#   be captured, and never more than the amount.
# - amount_received (captured) is never more than the amount, and refunds never
#   total more than was captured. Refunds reserve against amount_refunded before
#   the acquirer is asked, so this one constraint is what stops two concurrent
#   refunds from over-refunding even if the application's check were wrong.
# - A succeeded intent has received money; one waiting for capture has an
#   authorization with an acquirer reference and an expiry.
#
# Object-valued columns are `json`, not `jsonb`. jsonb stores keys in its own order
# (shortest first), so a merchant's metadata, or a last_payment_error rendered
# from it, would come back reordered. `json` keeps the text as written, and
# nothing queries inside these columns.
#
# The app role may insert and update intents, never delete them.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE payment_intents (
        id                       text PRIMARY KEY CHECK (id ~ '^pi_[A-Za-z0-9]{24}$'),
        merchant_id              text NOT NULL REFERENCES merchants (id),
        amount                   bigint NOT NULL CHECK (amount > 0),
        currency                 text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
        amount_capturable        bigint NOT NULL DEFAULT 0,
        amount_received          bigint NOT NULL DEFAULT 0,
        amount_refunded          bigint NOT NULL DEFAULT 0,
        status                   text NOT NULL CHECK (status IN (
                                   'requires_payment_method', 'requires_confirmation', 'processing',
                                   'requires_capture', 'succeeded', 'canceled')),
        capture_method           text NOT NULL CHECK (capture_method IN ('automatic', 'manual')),
        payment_method           text,
        customer_email           text,
        metadata                 json NOT NULL DEFAULT '{}'::json CHECK (json_typeof(metadata) = 'object'),
        latest_charge            text UNIQUE CHECK (latest_charge ~ '^ch_[A-Za-z0-9]{24}$'),
        last_payment_error       json,
        cancellation_reason      text,
        -- What the merchant sent for risk scoring, passed to RiskGate as is (M6).
        risk_fields              json NOT NULL DEFAULT '{}'::json CHECK (json_typeof(risk_fields) = 'object'),
        -- RiskGate's assessment, rendered as the intent's `risk` field (M6).
        risk                     json,
        acquirer_reference       text,
        authorized_at            timestamptz,
        authorization_expires_at timestamptz,
        -- Confirmation attempts. Each attempt has its own acquirer idempotency key.
        attempt                  integer NOT NULL DEFAULT 0 CHECK (attempt >= 0),
        lock_version             integer NOT NULL DEFAULT 0 CHECK (lock_version >= 0),
        created_at               timestamptz NOT NULL,
        updated_at               timestamptz NOT NULL,

        CONSTRAINT payment_intents_capturable_range
          CHECK (amount_capturable >= 0 AND amount_capturable <= amount),
        CONSTRAINT payment_intents_received_range
          CHECK (amount_received >= 0 AND amount_received <= amount),
        CONSTRAINT payment_intents_refunds_within_received
          CHECK (amount_refunded >= 0 AND amount_refunded <= amount_received),
        CONSTRAINT payment_intents_capturable_only_when_waiting
          CHECK (amount_capturable = 0 OR status = 'requires_capture'),
        CONSTRAINT payment_intents_waiting_has_authorization
          CHECK (status <> 'requires_capture' OR (amount_capturable > 0 AND acquirer_reference IS NOT NULL
                                                  AND authorization_expires_at IS NOT NULL)),
        CONSTRAINT payment_intents_succeeded_received
          CHECK (status <> 'succeeded' OR amount_received > 0),
        CONSTRAINT payment_intents_received_only_when_succeeded
          CHECK (amount_received = 0 OR status = 'succeeded')
      );
      -- The list endpoint pages newest first within one merchant.
      CREATE INDEX payment_intents_merchant_created ON payment_intents (merchant_id, created_at DESC, id DESC);
      -- The expiry sweep only ever looks at authorizations waiting for capture.
      CREATE INDEX payment_intents_authorization_expiry ON payment_intents (authorization_expires_at)
        WHERE status = 'requires_capture';
    SQL
    run 'GRANT SELECT, INSERT, UPDATE ON payment_intents TO clearinghouse_app'
  end

  down do
    drop_table(:payment_intents)
  end
end
