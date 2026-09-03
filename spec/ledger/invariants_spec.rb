# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Ledger::Invariants, :db do
  # Writes straight past every trigger and foreign key, the way only a superuser
  # could, to prove the invariant checks see damage the database would normally
  # have refused.
  def smuggle(entries, flow_id: 'bad_1')
    owner_db.transaction do
      owner_db.run('SET LOCAL session_replication_role = replica')
      txn = owner_db[:ledger_transactions].insert(flow_id: flow_id, flow_type: 'payment', description: 'smuggled',
                                                  effective_at: LedgerHelpers::T0, created_xact: 0)
      entries.each do |code, side, amount, currency|
        account = owner_db[:ledger_accounts].where(code: code, currency: currency).get(:id)
        owner_db[:ledger_entries].insert(transaction_id: txn, account_id: account, side: side, amount: amount,
                                         currency: currency)
      end
      txn
    end
  end

  before do
    post([debit('platform:cash', money(1000)), credit('merchant:m1:available', money(1000))])
    post([debit('platform:cash', money(50, 'jpy')), credit('merchant:m1:available', money(50, 'jpy'))],
         flow_id: 'pi_2')
  end

  it 'holds after ordinary postings and reversals' do
    Clearinghouse::Ledger.reverse!(app_db, 1, reason: 'test', effective_at: LedgerHelpers::T0)
    expect(described_class.check(app_db)).to eq([])
    expect { described_class.check!(app_db) }.not_to raise_error
  end

  it 'reports an unbalanced transaction under zero_sum and balanced_transactions' do
    txn = smuggle([['platform:cash', 'D', 7, 'jpy']])
    violations = described_class.check(app_db).map { |v| [v.invariant, v.detail] }
    expect(violations).to include(
      [:zero_sum, 'jpy debits minus credits is 7 JPY'],
      [:balanced_transactions, "transaction #{txn} has 1 entries"],
      [:balanced_transactions, "transaction #{txn} is off by 7 JPY"]
    )
  end

  it 'reports a transaction with no entries' do
    txn = smuggle([])
    expect(described_class.balanced_transactions(app_db).map(&:detail)).to eq(["transaction #{txn} has 0 entries"])
  end

  it 'reports balances that no longer match entries, including after a smuggled but balanced write' do
    smuggle([['platform:cash', 'D', 5, 'usd'], ['merchant:m1:available', 'C', 5, 'usd']])
    expect(described_class.zero_sum(app_db)).to be_empty
    expect(described_class.check(app_db).map(&:invariant)).to eq(%i[balances_match_entries balances_match_entries])
  end

  it 'raises with every violation listed' do
    smuggle([['platform:cash', 'C', 3, 'usd']])
    expect { described_class.check!(app_db) }.to raise_error(described_class::ViolationError) { |e|
      expect(e.violations.map(&:invariant).uniq).to eq(%i[zero_sum balanced_transactions balances_match_entries])
      expect(e.message).to start_with("ledger invariants violated:\n  zero_sum: usd debits minus credits is -0.03 USD")
    }
  end
end
