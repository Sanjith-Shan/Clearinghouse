# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Ledger::Checker, :db do
  let(:available) { 'merchant:m1:available' }

  def seed
    post([debit('platform:cash', money(10_000)), credit(available, money(9700)),
          credit('platform:fee_revenue', money(300))])
    post([debit(available, money(2500)), credit('platform:payout_clearing', money(2500))],
         flow_id: 'po_1', flow_type: 'payout')
    post([debit('platform:cash', money(900, 'jpy')), credit(available, money(900, 'jpy'))], flow_id: 'pi_2')
  end

  def account_id(code, currency = 'usd')
    app_db[:ledger_accounts].where(code: code, currency: currency).get(:id)
  end

  it 'reports an empty ledger as clean with nothing checked' do
    report = described_class.run(app_db)
    expect([report.clean?, report.accounts_checked]).to eq([true, 0])
  end

  it 'finds no drift after ordinary postings on debit- and credit-normal accounts' do
    seed
    report = described_class.run(app_db)
    expect(report.accounts_checked).to eq(6)
    expect(report.drifts).to be_empty
    expect(report).to be_clean
  end

  it 'treats an account with a balance row and no entries as clean' do
    app_db.transaction { Clearinghouse::Ledger.balance_for_update(app_db, available, 'eur') }
    expect(described_class.run(app_db)).to be_clean
  end

  it 'finds exactly the balance someone edited by hand, and by how much' do
    seed
    owner_db[:account_balances].where(account_id: account_id(available))
                               .update(balance: Sequel[:balance] + 1)
    report = described_class.run(app_db)
    expect(report).not_to be_clean
    drifts = report.drifts
    expect(drifts.length).to eq(1)
    drift = drifts.first
    expect([drift.code, drift.currency, drift.stored, drift.computed, drift.difference])
      .to eq([available, 'usd', 7201, 7200, 1])
    expect(drift.to_s).to eq('merchant:m1:available (usd): stored 72.01 USD, entries say 72.00 USD')
  end

  it 'reports a missing balance row as drift, not as zero' do
    seed
    owner_db[:account_balances].where(account_id: account_id('platform:cash', 'jpy')).delete
    drifts = described_class.run(app_db).drifts
    expect(drifts.length).to eq(1)
    drift = drifts.first
    expect([drift.code, drift.currency, drift.stored, drift.difference]).to eq(['platform:cash', 'jpy', nil, -900])
    expect(drift.to_s).to eq('platform:cash (jpy): stored no balance row, entries say 900 JPY')
  end

  it 'finds several drifts at once, in account order' do
    seed
    owner_db[:account_balances].update(balance: 0)
    expect(described_class.run(app_db).drifts.map(&:code))
      .to eq([available, 'platform:cash', 'platform:fee_revenue', 'platform:payout_clearing', available,
              'platform:cash'])
  end
end
