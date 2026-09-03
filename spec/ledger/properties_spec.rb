# typed: false
# frozen_string_literal: true

# Property tests over random postings. Each run starts from an empty database and
# compares the ledger against a plain-Ruby model of the balances.
RSpec.describe Clearinghouse::Ledger, :db do
  let(:g) { PropCheck::Generators }
  let(:account) do
    g.one_of(*%w[
      platform:cash platform:processor_receivable platform:refund_clearing platform:fee_revenue
      platform:processing_expense merchant:m1:available merchant:m1:pending merchant:m2:available
    ].map { |a| g.constant(a) })
  end
  let(:currency) { g.one_of(*%w[usd jpy kwd].map { |c| g.constant(c) }) }

  # A group is one currency's worth of a transaction: some debits, and credits
  # that split the same total. A transaction is one or two groups.
  let(:group) do
    g.fixed_hash(currency: currency,
                 debits: g.array(g.tuple(account, g.choose(1..5_000_000)), min: 1, max: 3),
                 credit_accounts: g.array(account, min: 1, max: 3))
  end
  let(:posting) { g.array(group, min: 1, max: 2) }
  let(:history) { g.array(posting, min: 1, max: 8) }

  def entries_for(groups)
    groups.flat_map do |grp|
      total = grp[:debits].sum(&:last)
      parts = grp[:credit_accounts].first([grp[:credit_accounts].length, total].min)
      share, remainder = total.divmod(parts.length)
      grp[:debits].map { |code, amount| debit(code, money(amount, grp[:currency])) } +
        parts.each_with_index.map { |code, i| credit(code, money(share + (i.zero? ? remainder : 0), grp[:currency])) }
    end
  end

  # Balances the model expects, signed on each account's normal side.
  def model(postings)
    postings.each_with_object(Hash.new(0)) do |entries, balances|
      entries.each do |e|
        normal = Clearinghouse::Ledger::AccountCode.parse(e.account).normal_side == e.side
        balances[[e.account, e.amount.currency]] += normal ? e.amount.amount : -e.amount.amount
      end
    end
  end

  def post_all(postings)
    postings.each_with_index.map { |entries, i| post(entries, flow_id: "f_#{i}", flow_type: 'test') }
  end

  def expect_ledger_matches(expected)
    actual = expected.keys.to_h { |code, cur| [[code, cur], balance_of(code, cur)] }
    expect(actual).to eq(expected)
    expect(app_db[:account_balances].count).to eq(expected.size)
    expect(Clearinghouse::Ledger::Invariants.check(app_db)).to eq([])
  end

  # The same entries as raw SQL in one database transaction, bypassing Ruby.
  def raw_insert(entries)
    ids = app_db[:ledger_accounts].to_hash(%i[code currency], :id)
    app_db.transaction do
      txn = app_db[:ledger_transactions].insert(flow_id: 'raw', flow_type: 'payment', description: 'raw',
                                                effective_at: LedgerHelpers::T0)
      app_db[:ledger_entries].multi_insert(entries.map do |e|
        { transaction_id: txn, account_id: ids.fetch([e.account, e.amount.currency]), side: e.side_column,
          amount: e.amount.amount, currency: e.amount.currency }
      end)
    end
  end

  def with_amount(entry, amount)
    Clearinghouse::Ledger::Entry.new(account: entry.account, side: entry.side,
                                     amount: money(amount, entry.amount.currency))
  end

  it 'keeps every invariant, and matches the model, under random balanced postings' do
    PropCheck::Property.new(history: history).with_config(n_runs: 40).check do |history:|
      DBHelper.clean!
      postings = history.map { |groups| entries_for(groups) }
      post_all(postings)
      expect_ledger_matches(model(postings))
    end
  end

  it 'always rejects an unbalanced posting, in Ruby and again in the database at commit' do
    PropCheck::Property.new(groups: posting, pick: g.nonnegative_integer, delta: g.choose(1..1000), up: g.boolean)
                       .with_config(n_runs: 40).check do |groups:, pick:, delta:, up:|
      DBHelper.clean!
      entries = entries_for(groups)
      index = pick % entries.length
      target = entries[index]
      change = up || target.amount.amount <= delta ? delta : -delta
      broken = entries.dup.tap { |b| b[index] = with_amount(target, target.amount.amount + change) }

      expect { post(broken) }.to raise_error(Clearinghouse::Ledger::UnbalancedError) { |e|
        expect(e.imbalances).to eq(target.amount.currency => target.side == :debit ? change : -change)
      }
      expect(app_db[:ledger_transactions].count).to eq(0)

      post(entries) # creates the accounts the raw insert needs
      expect { raw_insert(broken) }.to raise_error(Sequel::CheckConstraintViolation, /unbalanced/)
      expect(app_db[:ledger_transactions].count).to eq(1)
    end
  end

  it 'restores every balance when any one transaction is reversed' do
    PropCheck::Property.new(history: history, pick: g.nonnegative_integer)
                       .with_config(n_runs: 30).check do |history:, pick:|
      DBHelper.clean!
      postings = history.map { |groups| entries_for(groups) }
      ids = post_all(postings)
      index = pick % ids.length
      described_class.reverse!(app_db, ids[index], reason: 'property', effective_at: LedgerHelpers::T0)

      # Accounts first touched by the reversed transaction still exist, now at zero.
      expected = model(postings).transform_values { 0 }.merge(model(postings.reject.with_index { |_, i| i == index }))
      expect_ledger_matches(expected)
    end
  end
end
