# typed: false
# frozen_string_literal: true

# When a captured payment's net becomes available to pay out. One row per payment
# (flow id `pi_...`), written by the capture in the same transaction as the capture's
# ledger posting, and released by a sweep once the clock passes `available_on`.
#
# `released_at` is the whole idempotency story: the sweep claims due rows with
# FOR UPDATE SKIP LOCKED, posts the availability transaction and sets `released_at`
# in one database transaction, so a row is released exactly once however many
# sweeps run and wherever one crashes. The CHECKs keep the three release columns
# consistent: all set or none.
#
# flow_id has no foreign key to payment_intents on purpose: availability is a
# ledger-level schedule that must also work for flows posted without an intent row
# (the model tests and experiments do that).
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE scheduled_availabilities (
        id                     bigserial PRIMARY KEY,
        flow_id                text NOT NULL UNIQUE CHECK (flow_id ~ '^pi_[A-Za-z0-9]+$'),
        merchant_id            text NOT NULL REFERENCES merchants (id),
        amount                 bigint NOT NULL CHECK (amount > 0),
        currency               text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
        available_on           timestamptz NOT NULL,
        created_at             timestamptz NOT NULL,
        released_at            timestamptz,
        -- Where the release put the money: 'available', or 'held' while the payment
        -- is under risk review.
        released_to            text CHECK (released_to IN ('available', 'held')),
        release_transaction_id bigint REFERENCES ledger_transactions (id),
        CONSTRAINT scheduled_availabilities_release_complete CHECK (
          (released_at IS NULL AND released_to IS NULL AND release_transaction_id IS NULL) OR
          (released_at IS NOT NULL AND released_to IS NOT NULL AND release_transaction_id IS NOT NULL))
      );
      -- The sweep's query: unreleased rows by due time.
      CREATE INDEX scheduled_availabilities_due ON scheduled_availabilities (available_on, id)
        WHERE released_at IS NULL;
      CREATE INDEX scheduled_availabilities_merchant ON scheduled_availabilities (merchant_id, currency);
    SQL
    run 'GRANT SELECT, INSERT, UPDATE ON scheduled_availabilities TO clearinghouse_app'
  end

  down do
    drop_table(:scheduled_availabilities)
  end
end
