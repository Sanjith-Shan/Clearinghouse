# typed: false
# frozen_string_literal: true

# Reading the acquirer's notification feed (dispute.opened, dispute.closed,
# payout.paid, payout.failed) exactly once in effect.
#
# - acquirer_cursors holds how far each named consumer has read. It moves in the
#   same database transaction as the effects of the notification it passes, so a
#   crash can never leave the cursor ahead of the work.
# - processed_notifications has one row per notification whose effects committed,
#   written in that same transaction. The cursor alone would be enough for one
#   poller; the row is what makes a second poller, a rewound cursor or a replayed
#   page harmless, because a notification id can only be inserted once.
#
# Both are the poller's bookkeeping. The app role may add and read them, and may
# move a cursor, and nothing else.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE acquirer_cursors (
        name       text PRIMARY KEY CHECK (name ~ '^[a-z0-9_.-]{1,64}$'),
        cursor     text NOT NULL,
        updated_at timestamptz NOT NULL
      );

      CREATE TABLE processed_notifications (
        id           text PRIMARY KEY CHECK (id ~ '^ntf_[A-Za-z0-9]+$'),
        type         text NOT NULL,
        cursor       text NOT NULL,
        data         json NOT NULL CHECK (json_typeof(data) = 'object'),
        -- When the acquirer says it happened (the notification's due time), and when
        -- we handled it, both in simulated time.
        occurred_at  timestamptz NOT NULL,
        processed_at timestamptz NOT NULL
      );
    SQL
    run 'GRANT SELECT, INSERT, UPDATE ON acquirer_cursors TO clearinghouse_app'
    run 'GRANT SELECT, INSERT ON processed_notifications TO clearinghouse_app'
  end

  down do
    drop_table(:processed_notifications)
    drop_table(:acquirer_cursors)
  end
end
