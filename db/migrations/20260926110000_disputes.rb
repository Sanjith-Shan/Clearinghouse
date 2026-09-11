# typed: false
# frozen_string_literal: true

# Disputes (chargebacks). A row is created when the acquirer's dispute.opened
# notification is handled, in the same transaction as the dispute-opened ledger
# posting and the charge.dispute.created event, and it points at that posting.
#
# - acquirer_dispute_id is unique, the backstop against applying one dispute twice
#   if the poller's own dedupe were ever bypassed.
# - Disputes and settlement lines find their payment by the acquirer's reference,
#   so payment_intents gets an index on it.
# - A closed dispute has a close time, an open one does not, and a won dispute
#   points at the posting that returned the merchant's money.
#
# The app role may insert, read and update disputes (status changes), never delete.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE disputes (
        id                    text PRIMARY KEY CHECK (id ~ '^dp_[A-Za-z0-9]{24}$'),
        merchant_id           text NOT NULL REFERENCES merchants (id),
        payment_intent        text NOT NULL REFERENCES payment_intents (id),
        amount                bigint NOT NULL CHECK (amount > 0),
        fee                   bigint NOT NULL CHECK (fee >= 0),
        currency              text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
        reason                text NOT NULL,
        status                text NOT NULL CHECK (status IN ('needs_response', 'won', 'lost')),
        closed_by             text CHECK (closed_by IN ('acquirer', 'merchant')),
        acquirer_dispute_id   text NOT NULL UNIQUE,
        acquirer_reference    text NOT NULL,
        opened_transaction_id bigint NOT NULL REFERENCES ledger_transactions (id),
        won_transaction_id    bigint REFERENCES ledger_transactions (id),
        -- Simulated times: when the acquirer opened it, and when it was closed.
        created_at            timestamptz NOT NULL,
        closed_at             timestamptz,
        updated_at            timestamptz NOT NULL,

        CONSTRAINT disputes_closed_consistently
          CHECK ((status = 'needs_response') = (closed_at IS NULL AND closed_by IS NULL)),
        CONSTRAINT disputes_won_has_posting
          CHECK ((status = 'won') = (won_transaction_id IS NOT NULL))
      );
      CREATE INDEX disputes_merchant_created ON disputes (merchant_id, created_at DESC, id DESC);
      CREATE INDEX disputes_acquirer_reference ON disputes (acquirer_reference);
      CREATE INDEX payment_intents_acquirer_reference ON payment_intents (acquirer_reference);
    SQL
    run 'GRANT SELECT, INSERT, UPDATE ON disputes TO clearinghouse_app'
  end

  down do
    run 'DROP INDEX payment_intents_acquirer_reference'
    drop_table(:disputes)
  end
end
