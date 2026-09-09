# typed: false
# frozen_string_literal: true

# Risk-review holds (Stripe calls them Reviews). One per payment that RiskGate
# answered `review` for. While a hold is open, the payment's net is released to
# the merchant's held account instead of available, so no payout can include it.
#
# `held_amount` is how much of this payment is sitting in the held account right
# now. It is what approve, and the refund after a reject, move back to available,
# so the hold never has to recompute where its money is.
#
# The CHECKs spell out the lifecycle: open (closed_at NULL) or closed with a
# resolution; only a rejected hold has a refund; an approved hold, and a rejected
# one whose refund has posted, hold nothing.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE risk_holds (
        id                text PRIMARY KEY CHECK (id ~ '^prv_[A-Za-z0-9]{24}$'),
        flow_id           text NOT NULL UNIQUE CHECK (flow_id ~ '^pi_[A-Za-z0-9]+$'),
        merchant_id       text NOT NULL REFERENCES merchants (id),
        amount            bigint NOT NULL CHECK (amount > 0),
        currency          text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
        reason            text NOT NULL,
        opened_at         timestamptz NOT NULL,
        closed_at         timestamptz,
        resolution        text CHECK (resolution IN ('approved', 'rejected')),
        held_amount       bigint NOT NULL DEFAULT 0 CHECK (held_amount >= 0),
        refund_id         text,
        refund_applied_at timestamptz,

        CONSTRAINT risk_holds_closed_has_resolution CHECK ((closed_at IS NULL) = (resolution IS NULL)),
        CONSTRAINT risk_holds_refund_only_when_rejected
          CHECK (resolution IS NOT DISTINCT FROM 'rejected' OR (refund_id IS NULL AND refund_applied_at IS NULL)),
        CONSTRAINT risk_holds_approved_holds_nothing
          CHECK (resolution IS DISTINCT FROM 'approved' OR held_amount = 0),
        CONSTRAINT risk_holds_refunded_holds_nothing CHECK (refund_applied_at IS NULL OR held_amount = 0)
      );
      CREATE INDEX risk_holds_merchant_opened ON risk_holds (merchant_id, opened_at DESC, id DESC);
    SQL
    run 'GRANT SELECT, INSERT, UPDATE ON risk_holds TO clearinghouse_app'
  end

  down do
    drop_table(:risk_holds)
  end
end
