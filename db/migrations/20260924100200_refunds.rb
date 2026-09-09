# typed: false
# frozen_string_literal: true

# Refunds. A refund is created `pending` with its amount reserved on the payment
# intent (payment_intents.amount_refunded), then becomes `succeeded` or `failed`
# once the acquirer answers; a failure releases the reservation. The intent's
# check constraint (amount_refunded <= amount_received) is what makes the total
# of all refunds impossible to push past what was captured.
#
# The app role may create and update refunds, never delete them.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE refunds (
        id                text PRIMARY KEY CHECK (id ~ '^re_[A-Za-z0-9]{24}$'),
        merchant_id       text NOT NULL REFERENCES merchants (id),
        payment_intent_id text NOT NULL REFERENCES payment_intents (id),
        amount            bigint NOT NULL CHECK (amount > 0),
        currency          text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
        status            text NOT NULL CHECK (status IN ('pending', 'succeeded', 'failed')),
        reason            text CHECK (reason IN ('duplicate', 'fraudulent', 'requested_by_customer')),
        failure_reason    text,
        metadata          json NOT NULL DEFAULT '{}'::json CHECK (json_typeof(metadata) = 'object'),
        created_at        timestamptz NOT NULL,
        updated_at        timestamptz NOT NULL,
        CONSTRAINT refunds_failure_reason_only_when_failed CHECK ((status = 'failed') = (failure_reason IS NOT NULL))
      );
      CREATE INDEX refunds_payment_intent ON refunds (payment_intent_id, created_at);
    SQL
    run 'GRANT SELECT, INSERT, UPDATE ON refunds TO clearinghouse_app'
  end

  down do
    drop_table(:refunds)
  end
end
