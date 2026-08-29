# typed: false
# frozen_string_literal: true

# The ledger. Four tables, and the rules that make it a ledger live here in the
# database rather than only in Ruby:
#
# - Double entry. A deferred constraint trigger checks, at COMMIT, that every
#   transaction has at least two entries and that its debits equal its credits in
#   each currency. It is deferred because a transaction's entries arrive in
#   separate statements after its header row, so any per-statement check would see
#   a half-written transaction.
# - Append-only. Triggers reject UPDATE, DELETE and TRUNCATE on accounts,
#   transactions and entries, and the app role is only granted SELECT and INSERT on
#   them. Either layer alone would stop an edit; both exist so a mistake in one
#   (a stray GRANT, a dropped trigger) does not open history to rewriting.
# - No late entries. Entries can only be added in the same database transaction
#   that created their ledger transaction. Otherwise a balanced pair of entries
#   could be appended to a transaction that committed last week, which edits
#   history without an UPDATE.
# - Currency. An entry's currency must equal its account's currency, enforced by a
#   composite foreign key.
# - Reversals. A transaction is reversed at most once (unique index), a reversal
#   cannot itself be reversed, it stays in the original's flow, and at commit its
#   entries must exactly mirror the original's.
#
# account_balances is the one mutable table. The app keeps it in step with entries
# inside the posting transaction, and Ledger::Checker recomputes it from entries.
Sequel.migration do
  up do
    run <<~SQL
      CREATE TABLE ledger_accounts (
        id          bigserial PRIMARY KEY,
        code        text NOT NULL,
        currency    text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
        kind        text NOT NULL CHECK (kind IN ('asset', 'liability', 'revenue', 'expense', 'clearing')),
        normal_side char(1) NOT NULL CHECK (normal_side IN ('D', 'C')),
        owner_id    text,
        created_at  timestamptz NOT NULL DEFAULT now(),
        UNIQUE (code, currency),
        -- Target of the entries' composite foreign key, which is what ties an
        -- entry's currency to its account's.
        UNIQUE (id, currency)
      );

      CREATE TABLE ledger_transactions (
        id                      bigserial PRIMARY KEY,
        flow_id                 text NOT NULL CHECK (flow_id <> ''),
        flow_type               text NOT NULL CHECK (flow_type <> ''),
        description             text NOT NULL,
        effective_at            timestamptz NOT NULL,
        created_at              timestamptz NOT NULL DEFAULT now(),
        reverses_transaction_id bigint UNIQUE REFERENCES ledger_transactions (id),
        -- Set by trigger, never by the caller. See ledger_entries_same_xact.
        created_xact            bigint NOT NULL,
        CHECK (reverses_transaction_id IS NULL OR reverses_transaction_id <> id)
      );
      CREATE INDEX ledger_transactions_flow_id ON ledger_transactions (flow_id);
      CREATE INDEX ledger_transactions_flow_type_effective_at ON ledger_transactions (flow_type, effective_at);

      CREATE TABLE ledger_entries (
        id             bigserial PRIMARY KEY,
        transaction_id bigint NOT NULL REFERENCES ledger_transactions (id),
        account_id     bigint NOT NULL,
        side           char(1) NOT NULL CHECK (side IN ('D', 'C')),
        amount         bigint NOT NULL CHECK (amount > 0),
        currency       text NOT NULL,
        FOREIGN KEY (account_id, currency) REFERENCES ledger_accounts (id, currency)
      );
      CREATE INDEX ledger_entries_transaction_id ON ledger_entries (transaction_id);
      CREATE INDEX ledger_entries_account_id ON ledger_entries (account_id);

      CREATE TABLE account_balances (
        account_id bigint PRIMARY KEY REFERENCES ledger_accounts (id),
        balance    bigint NOT NULL DEFAULT 0,
        version    bigint NOT NULL DEFAULT 0 CHECK (version >= 0)
      );
    SQL

    # Append-only. One function serves every protected table and every operation.
    run <<~SQL
      CREATE FUNCTION ledger_reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is append-only: % is not allowed; post a reversal instead', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'object_not_in_prerequisite_state';
      END;
      $$;
    SQL
    %w[ledger_accounts ledger_transactions ledger_entries].each do |table|
      run <<~SQL
        CREATE TRIGGER #{table}_no_update_delete BEFORE UPDATE OR DELETE ON #{table}
          FOR EACH ROW EXECUTE FUNCTION ledger_reject_mutation();
        CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table}
          FOR EACH STATEMENT EXECUTE FUNCTION ledger_reject_mutation();
      SQL
    end

    # Header-row rules that can be checked at insert time.
    run <<~SQL
      CREATE FUNCTION ledger_transactions_before_insert() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        target ledger_transactions%ROWTYPE;
        other_type text;
      BEGIN
        -- Always overwritten, so a caller cannot pick a future transaction id and
        -- smuggle entries in later.
        NEW.created_xact := txid_current();

        SELECT flow_type INTO other_type FROM ledger_transactions
          WHERE flow_id = NEW.flow_id AND flow_type <> NEW.flow_type LIMIT 1;
        IF FOUND THEN
          RAISE EXCEPTION 'flow % already has flow_type %, not %', NEW.flow_id, other_type, NEW.flow_type
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.reverses_transaction_id IS NOT NULL THEN
          SELECT * INTO target FROM ledger_transactions WHERE id = NEW.reverses_transaction_id;
          IF FOUND AND target.reverses_transaction_id IS NOT NULL THEN
            RAISE EXCEPTION 'transaction % is itself a reversal and cannot be reversed', target.id
              USING ERRCODE = 'check_violation';
          END IF;
          IF FOUND AND target.flow_id <> NEW.flow_id THEN
            RAISE EXCEPTION 'a reversal must stay in flow %, got %', target.flow_id, NEW.flow_id
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER ledger_transactions_before_insert BEFORE INSERT ON ledger_transactions
        FOR EACH ROW EXECUTE FUNCTION ledger_transactions_before_insert();
    SQL

    run <<~SQL
      CREATE FUNCTION ledger_entries_same_xact() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM ledger_transactions
                        WHERE id = NEW.transaction_id AND created_xact = txid_current()) THEN
          RAISE EXCEPTION 'entries for ledger transaction % must be written in the database transaction that created it',
            NEW.transaction_id USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER ledger_entries_same_xact BEFORE INSERT ON ledger_entries
        FOR EACH ROW EXECUTE FUNCTION ledger_entries_same_xact();
    SQL

    # The double-entry check, run at COMMIT. It fires from both tables: from
    # ledger_transactions so a header with no entries is caught, and from
    # ledger_entries so every transaction that gained entries is re-checked.
    run <<~SQL
      CREATE FUNCTION ledger_check_transaction() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        txn_id bigint;
        entry_count integer;
        reversed_id bigint;
        bad record;
      BEGIN
        IF TG_TABLE_NAME = 'ledger_transactions' THEN
          txn_id := NEW.id;
        ELSE
          txn_id := NEW.transaction_id;
        END IF;

        SELECT count(*) INTO entry_count FROM ledger_entries WHERE transaction_id = txn_id;
        IF entry_count < 2 THEN
          RAISE EXCEPTION 'ledger transaction % has % entries, needs at least 2', txn_id, entry_count
            USING ERRCODE = 'check_violation';
        END IF;

        FOR bad IN
          SELECT currency, sum(CASE side WHEN 'D' THEN amount ELSE -amount END) AS net
            FROM ledger_entries WHERE transaction_id = txn_id
            GROUP BY currency
            HAVING sum(CASE side WHEN 'D' THEN amount ELSE -amount END) <> 0
        LOOP
          RAISE EXCEPTION 'ledger transaction % is unbalanced in %: debits minus credits is %',
            txn_id, bad.currency, bad.net USING ERRCODE = 'check_violation';
        END LOOP;

        SELECT reverses_transaction_id INTO reversed_id FROM ledger_transactions WHERE id = txn_id;
        IF reversed_id IS NOT NULL AND EXISTS (
          SELECT 1 FROM (
            SELECT account_id, CASE side WHEN 'D' THEN amount ELSE -amount END AS signed
              FROM ledger_entries WHERE transaction_id IN (txn_id, reversed_id)
          ) both_sides
          GROUP BY account_id HAVING sum(signed) <> 0
        ) THEN
          RAISE EXCEPTION 'ledger transaction % does not exactly mirror transaction % that it reverses',
            txn_id, reversed_id USING ERRCODE = 'check_violation';
        END IF;
        RETURN NULL;
      END;
      $$;
      CREATE CONSTRAINT TRIGGER ledger_transactions_balanced AFTER INSERT ON ledger_transactions
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger_check_transaction();
      CREATE CONSTRAINT TRIGGER ledger_entries_balanced AFTER INSERT ON ledger_entries
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger_check_transaction();
    SQL

    # The app may read and append history, and may maintain balances. Nothing else.
    run 'GRANT SELECT, INSERT ON ledger_accounts, ledger_transactions, ledger_entries TO clearinghouse_app'
    run 'GRANT SELECT, INSERT, UPDATE ON account_balances TO clearinghouse_app'
  end

  down do
    run 'DROP TABLE account_balances, ledger_entries, ledger_transactions, ledger_accounts'
    run 'DROP FUNCTION ledger_check_transaction(), ledger_entries_same_xact(), ' \
        'ledger_transactions_before_insert(), ledger_reject_mutation()'
  end
end
