# typed: false
# frozen_string_literal: true

# Every foreign key needs an index whose leading columns are its referencing
# columns. Without one, each delete (or key update) of a referenced row makes
# Postgres seq-scan the referencing table to check or apply the ON DELETE action,
# so bulk deletes cost rows deleted x rows referencing, and nothing fails: it only
# gets slower as both tables grow. docs/bugs/idempotency-reaper-fk-seq-scan.md is
# the one that got through.
RSpec.describe 'foreign key indexes', :db do
  # Foreign keys that may go without an index, "table.constraint" => why. Only for
  # a referenced table whose rows are never deleted and whose key never changes,
  # so the check never runs. Whether reads want an index is a separate question.
  let(:allowed_unindexed) do
    ledger = 'ledger tables are append-only: a trigger rejects every UPDATE and DELETE'
    merchants = 'the app role may only SELECT and INSERT merchants'
    {
      'disputes.disputes_opened_transaction_id_fkey' => ledger,
      'disputes.disputes_won_transaction_id_fkey' => ledger,
      'ledger_entries.ledger_entries_account_id_currency_fkey' => ledger,
      'payouts.payouts_reserve_transaction_id_fkey' => ledger,
      'reconciliation_exceptions.reconciliation_exceptions_resolution_transaction_id_fkey' => ledger,
      'scheduled_availabilities.scheduled_availabilities_release_transaction_id_fkey' => ledger,
      'settlement_lines.settlement_lines_ledger_transaction_id_fkey' => ledger,
      'refunds.refunds_merchant_id_fkey' => merchants,
      'webhook_endpoints.webhook_endpoints_merchant_id_fkey' => merchants,
      'disputes.disputes_payment_intent_fkey' =>
        'the app role cannot DELETE payment intents, and no code path changes an intent id',
      'reconciliation_exceptions.reconciliation_exceptions_settlement_line_id_fkey' =>
        'the app role may only INSERT settlement lines and UPDATE outcome, flow_id and ledger_transaction_id'
    }
  end

  # One row per foreign key in the public schema with no usable index. An index
  # is usable when it is valid, its leading columns are exactly the key's columns
  # (in any order: the check is an equality on all of them), and it is either
  # total or partial on "<column> IS NOT NULL", which the check always implies.
  def unindexed
    owner_db.fetch(<<~SQL).all
      SELECT c.conrelid::regclass::text AS table_name, c.conname AS constraint_name,
             c.confrelid::regclass::text AS referenced,
             (SELECT string_agg(a.attname, ', ' ORDER BY k.ord)
                FROM unnest(c.conkey) WITH ORDINALITY AS k (attnum, ord)
                JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum) AS columns
        FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
       WHERE c.contype = 'f' AND n.nspname = 'public'
         AND NOT EXISTS (
           SELECT 1
             FROM pg_index i
            WHERE i.indrelid = c.conrelid AND i.indisvalid
              AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey
              AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] <@ c.conkey
              AND (i.indpred IS NULL
                   OR (cardinality(c.conkey) = 1
                       AND pg_get_expr(i.indpred, i.indrelid) =
                           format('(%I IS NOT NULL)',
                                  (SELECT attname FROM pg_attribute
                                    WHERE attrelid = c.conrelid AND attnum = c.conkey[1])))))
       ORDER BY 1, 2
    SQL
  end

  it 'finds the foreign keys it is checking' do
    count = owner_db.fetch(<<~SQL).get(:n)
      SELECT count(*) AS n FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
       WHERE c.contype = 'f' AND n.nspname = 'public'
    SQL
    expect(count).to be > 10
  end

  it 'has an index leading with the columns of every foreign key' do
    missing = unindexed
              .reject { |r| allowed_unindexed.key?("#{r[:table_name]}.#{r[:constraint_name]}") }
              .map { |r| "#{r[:table_name]} (#{r[:columns]}) -> #{r[:referenced]}: #{r[:constraint_name]}" }
    expect(missing).to be_empty, "foreign keys without an index:\n  #{missing.join("\n  ")}"
  end

  it 'only allows foreign keys that still exist and are still unindexed' do
    flagged = unindexed.map { |r| "#{r[:table_name]}.#{r[:constraint_name]}" }
    expect(allowed_unindexed.keys - flagged).to be_empty
  end

  # The reaper deletes finished idempotency keys in bulk, and
  # payment_intents.locked_by is ON DELETE SET NULL. Postgres applies that with
  # `UPDATE ONLY payment_intents SET locked_by = NULL WHERE $1 = locked_by`, planned
  # once and reused for every deleted key, so the generic plan is what runs. With
  # seq scans priced out, a plan that still scans the table has no index to use.
  it 'plans the reaper cascade into payment_intents as an index lookup' do
    plan = owner_db.transaction(rollback: :always) do
      owner_db.run('SET LOCAL enable_seqscan = off')
      owner_db.fetch(<<~SQL).get(:'QUERY PLAN')
        EXPLAIN (GENERIC_PLAN, FORMAT JSON) UPDATE ONLY payment_intents SET locked_by = NULL WHERE $1 = locked_by
      SQL
    end
    scan = JSON.parse(plan).first.dig('Plan', 'Plans', 0)
    expect(scan).to include('Node Type' => 'Index Scan', 'Index Name' => 'payment_intents_locked_by')
  end
end
