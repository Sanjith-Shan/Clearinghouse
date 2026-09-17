# typed: false
# frozen_string_literal: true

# Settlement files as the acquirer sent them, their lines, and the reconciliation
# exceptions an operator works through.
#
# - settlement_files keeps the raw bytes and their SHA-256, one file per date. The
#   acquirer freezes a file once generated, so a second fetch of a date must hash the
#   same; the reconciler refuses one that does not.
#   requested_at is the simulated time the file was asked for (its Sim-Time).
#   fetched_at is the database's clock_timestamp() just before the request, the same
#   clock ledger_transactions.created_at comes from, so the two can be ordered: a
#   posting made before a fetch was known to the acquirer when it built the file.
# - settlement_lines is one row per CSV row, in file order. `outcome` is what the
#   reconciler did with it; `flow_id` and `ledger_transaction_id` say where it went.
#   Only those three columns can change (a pending line matched later).
# - refunds.acquirer_operation_id is the acquirer's id for the refund operation. It is
#   the operation_id of the refund's settlement line, and the only way to tell two
#   refunds of one payment apart in a file. Unique: one operation, one refund.
# - reconciliation_exceptions: typed reasons, open until an operator resolves them
#   with a note and, optionally, a ledger posting. At most one `missing` exception per
#   expected line, so the SLA job can run as often as it likes.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE settlement_files (
        id           bigserial PRIMARY KEY,
        settled_on   date NOT NULL UNIQUE,
        sha256       text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
        raw          text NOT NULL,
        line_count   integer NOT NULL CHECK (line_count >= 0),
        requested_at timestamptz NOT NULL,
        fetched_at   timestamptz NOT NULL,
        ingested_at  timestamptz NOT NULL
      );

      CREATE TABLE settlement_lines (
        id                    bigserial PRIMARY KEY,
        file_id               bigint NOT NULL REFERENCES settlement_files (id),
        position              integer NOT NULL CHECK (position >= 1),
        line_id               text NOT NULL,
        type                  text NOT NULL CHECK (type IN ('capture', 'refund', 'dispute', 'dispute_reversal')),
        acquirer_reference    text NOT NULL,
        operation_id          text NOT NULL,
        amount                bigint NOT NULL,
        fee                   bigint NOT NULL,
        currency              text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
        settled_on            date NOT NULL,
        outcome               text NOT NULL CHECK (outcome IN
                                ('cleared', 'late', 'mismatch', 'duplicate', 'unknown', 'pending')),
        flow_id               text,
        ledger_transaction_id bigint REFERENCES ledger_transactions (id),
        UNIQUE (file_id, position),
        CONSTRAINT settlement_lines_posted_when_cleared
          CHECK (outcome NOT IN ('cleared', 'late') OR ledger_transaction_id IS NOT NULL)
      );
      -- Duplicate detection is by the acquirer's identity of the movement.
      CREATE INDEX settlement_lines_identity ON settlement_lines (acquirer_reference, type, operation_id);
      CREATE INDEX settlement_lines_flow ON settlement_lines (flow_id, type);
      CREATE INDEX settlement_lines_pending ON settlement_lines (id) WHERE outcome = 'pending';

      CREATE TABLE reconciliation_exceptions (
        id                        text PRIMARY KEY CHECK (id ~ '^rex_[A-Za-z0-9]{24}$'),
        reason                    text NOT NULL CHECK (reason IN
                                    ('missing', 'duplicate', 'amount_mismatch', 'fee_mismatch', 'late',
                                     'unknown_payment')),
        status                    text NOT NULL CHECK (status IN ('open', 'resolved')),
        settlement_line_id        bigint REFERENCES settlement_lines (id),
        flow_id                   text,
        flow_type                 text,
        merchant_id               text,
        line_type                 text NOT NULL,
        acquirer_reference        text,
        operation_id              text,
        currency                  text NOT NULL,
        expected_amount           bigint,
        expected_fee              bigint,
        -- Signed on the clearing account's normal side: what this exception leaves
        -- unexplained in that account. Zero when nothing is stuck.
        clearing_account          text,
        unexplained_amount        bigint NOT NULL DEFAULT 0,
        detail                    text NOT NULL,
        created_at                timestamptz NOT NULL,
        resolved_at               timestamptz,
        resolution_action         text CHECK (resolution_action IN ('none', 'write_off', 'reverse', 'auto')),
        resolution_note           text,
        resolution_transaction_id bigint REFERENCES ledger_transactions (id),
        CONSTRAINT reconciliation_exceptions_resolved_fully
          CHECK ((status = 'resolved') = (resolved_at IS NOT NULL AND resolution_action IS NOT NULL
                                          AND resolution_note IS NOT NULL)),
        CONSTRAINT reconciliation_exceptions_stuck_money_has_account
          CHECK (unexplained_amount = 0 OR (clearing_account IS NOT NULL AND flow_id IS NOT NULL))
      );
      CREATE UNIQUE INDEX reconciliation_exceptions_one_missing
        ON reconciliation_exceptions (flow_id, line_type) WHERE reason = 'missing';
      CREATE INDEX reconciliation_exceptions_status ON reconciliation_exceptions (status, created_at, id);
      CREATE INDEX reconciliation_exceptions_flow ON reconciliation_exceptions (flow_id);
    SQL
    run 'ALTER TABLE refunds ADD COLUMN acquirer_operation_id text UNIQUE'
    run 'GRANT SELECT, INSERT ON settlement_files TO clearinghouse_app'
    run 'GRANT SELECT, INSERT ON settlement_lines TO clearinghouse_app'
    run 'GRANT UPDATE (outcome, flow_id, ledger_transaction_id) ON settlement_lines TO clearinghouse_app'
    run 'GRANT SELECT, INSERT, UPDATE ON reconciliation_exceptions TO clearinghouse_app'
  end

  down do
    drop_table(:reconciliation_exceptions)
    drop_table(:settlement_lines)
    drop_table(:settlement_files)
    run 'ALTER TABLE refunds DROP COLUMN acquirer_operation_id'
  end
end
