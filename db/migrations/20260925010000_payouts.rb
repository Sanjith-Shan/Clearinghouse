# typed: false
# frozen_string_literal: true

# Payouts: money leaving a merchant's available balance for their bank.
#
# A payout is created in one transaction that locks the merchant's available
# balance row, checks it, inserts this row and posts available -> payout_clearing
# (reserve_transaction_id). The bank call happens after that commits, and
# `recovery_point` records how far the request got, so a crashed request can be
# resumed without calling the bank twice under different keys. See
# docs/design/payouts.md for the phases and the crash matrix.
#
# The CHECKs are the database's version of the state machine's invariants:
# a payout the bank has accepted has the bank's reference, a failed one says why,
# and only automatic payouts carry the day they were scheduled for, one per
# merchant, currency and day.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE payouts (
        id                     text PRIMARY KEY CHECK (id ~ '^po_[A-Za-z0-9]{24}$'),
        merchant_id            text NOT NULL REFERENCES merchants (id),
        amount                 bigint NOT NULL CHECK (amount > 0),
        currency               text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
        status                 text NOT NULL CHECK (status IN ('pending', 'in_transit', 'paid', 'failed', 'canceled')),
        recovery_point         text NOT NULL CHECK (recovery_point IN ('balance_reserved', 'bank_requested',
                                                                        'bank_recorded')),
        automatic              boolean NOT NULL DEFAULT false,
        scheduled_for          date,
        description            text,
        metadata               json NOT NULL DEFAULT '{}'::json CHECK (json_typeof(metadata) = 'object'),
        reserve_transaction_id bigint NOT NULL REFERENCES ledger_transactions (id),
        bank_idempotency_key   text UNIQUE,
        acquirer_reference     text UNIQUE,
        failure_code           text,
        arrival_date           timestamptz NOT NULL,
        created_at             timestamptz NOT NULL,
        updated_at             timestamptz NOT NULL,

        CONSTRAINT payouts_automatic_has_day CHECK (automatic = (scheduled_for IS NOT NULL)),
        CONSTRAINT payouts_failed_has_code CHECK ((status = 'failed') = (failure_code IS NOT NULL)),
        CONSTRAINT payouts_sent_has_reference CHECK (status NOT IN ('in_transit', 'paid')
                                                     OR acquirer_reference IS NOT NULL),
        CONSTRAINT payouts_requested_has_key CHECK (recovery_point = 'balance_reserved'
                                                    OR bank_idempotency_key IS NOT NULL),
        CONSTRAINT payouts_canceled_before_bank CHECK (status <> 'canceled' OR recovery_point = 'balance_reserved')
      );
      CREATE UNIQUE INDEX payouts_one_automatic_per_day ON payouts (merchant_id, currency, scheduled_for)
        WHERE automatic;
      -- The list endpoint pages newest first within one merchant.
      CREATE INDEX payouts_merchant_created ON payouts (merchant_id, created_at DESC, id DESC);
      -- The resume sweep only looks at payouts whose request has not finished.
      CREATE INDEX payouts_incomplete ON payouts (updated_at)
        WHERE status = 'pending' AND recovery_point IN ('balance_reserved', 'bank_requested');
    SQL
    run 'GRANT SELECT, INSERT, UPDATE ON payouts TO clearinghouse_app'
  end

  down do
    drop_table(:payouts)
  end
end
