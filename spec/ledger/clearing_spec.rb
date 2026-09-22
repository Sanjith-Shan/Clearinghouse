# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Ledger::Clearing, :db do
  let(:day) { MoneyFlowHelpers::DAY }
  let(:slas) { { 'payment' => 3 * day, 'refund' => 3 * day, 'dispute' => 30 * day, 'payout' => 2 * day } }
  let(:as_of) { LedgerHelpers::T0 + (8 * day) }
  let(:receivable) { 'platform:processor_receivable' }

  def usd(amount) = money(amount, 'usd')

  # Every row of the money-flow table, plus one payment still in flight and one
  # that leaks. Nothing below tells the report which flow is the leaky one.
  def build_world
    completed_flows
    unfinished_flows
  end

  def completed_flows
    flow_event('pi_1', :capture, day: 0, merchant_id: 'm1', gross: usd(100_000), fee: usd(2930))
    flow_event('pi_1', :settlement, day: 2, gross: usd(100_000), acquirer_fee: usd(1510))
    flow_event('pi_1', :funds_available, day: 2, merchant_id: 'm1', net: usd(97_070))

    flow_event('re_1', :refund, day: 3, merchant_id: 'm1', amount: usd(4000))
    flow_event('re_1', :refund_settled, day: 5, amount: usd(4000))

    flow_event('dp_1', :dispute_opened, day: 3, merchant_id: 'm1', amount: usd(5000), fee: usd(1500))
    flow_event('dp_1', :dispute_debited, day: 4, amount: usd(5000))
    flow_event('dp_1', :dispute_won, day: 6, merchant_id: 'm1', amount: usd(5000))
    flow_event('dp_1', :dispute_funds_returned, day: 7, amount: usd(5000))

    flow_event('dp_2', :dispute_opened, day: 3, merchant_id: 'm1', amount: usd(2000), fee: usd(1500))
    flow_event('dp_2', :dispute_debited, day: 4, amount: usd(2000)) # lost: nothing comes back

    flow_event('po_1', :payout, day: 3, merchant_id: 'm1', amount: usd(3000))
    flow_event('po_1', :payout_paid, day: 4, amount: usd(3000))
    flow_event('po_2', :payout, day: 3, merchant_id: 'm1', amount: usd(1000))
    flow_event('po_2', :payout_failed, day: 5, merchant_id: 'm1', amount: usd(1000))

    flow_event('pi_2', :capture, day: 0, merchant_id: 'm2', gross: money(5000, 'jpy'), fee: money(145, 'jpy'))
    flow_event('pi_2', :settlement, day: 2, gross: money(5000, 'jpy'), acquirer_fee: money(85, 'jpy'))
  end

  def unfinished_flows
    # In flight: captured yesterday, settles tomorrow.
    flow_event('pi_3', :capture, day: 7, merchant_id: 'm1', gross: usd(5000), fee: usd(175))

    # The leak: settlement booked against 99.00 instead of the 100.00 captured.
    flow_event('pi_4', :capture, day: 1, merchant_id: 'm1', gross: usd(10_000), fee: usd(320))
    flow_event('pi_4', :settlement, day: 3, gross: usd(9900), acquirer_fee: usd(159))
  end

  def report
    described_class.report(app_db, as_of: as_of, slas: slas)
  end

  it 'lets the leaky flow stand out without being told about it' do
    build_world
    result = report
    expect(result.open_flows.map(&:flow_id)).to eq(%w[pi_3 pi_4])
    leak = result.past_sla.first
    expect(result.past_sla.length).to eq(1)
    expect([leak.flow_id, leak.flow_type, leak.age_seconds, leak.sla_seconds])
      .to eq(['pi_4', 'payment', 7 * day, 3 * day])
    expect(leak.unexplained).to eq([receivable, 'usd'] => 100)
    expect(leak.opened_at).to eq(LedgerHelpers::T0 + day)
    expect(result).not_to be_healthy
    expect(result.flow_types_without_sla).to eq([])
  end

  it 'keeps an in-flight flow open but not overdue' do
    build_world
    in_flight = report.open_flows.first
    expect([in_flight.flow_id, in_flight.past_sla?, in_flight.unexplained])
      .to eq(['pi_3', false, { [receivable, 'usd'] => 5000 }])
  end

  it 'reports explainability per flow type and currency, by volume' do
    build_world
    rows = report.explainability.map do |e|
      [e.flow_type, e.currency, e.flows, e.explained_flows, e.volume, e.explained_volume, e.share]
    end
    expect(rows).to eq([
                         ['dispute', 'usd', 2, 2, 10_000, 10_000, 1],
                         ['payment', 'jpy', 1, 1, 5000, 5000, 1],
                         ['payment', 'usd', 3, 1, 115_000, 100_000, Rational(20, 23)],
                         ['payout', 'usd', 2, 2, 4000, 4000, 1],
                         ['refund', 'usd', 1, 1, 4000, 4000, 1]
                       ])
  end

  it 'finds no orphan clearing balances when every cent in clearing belongs to an open flow' do
    build_world
    expect(report.orphan_balances).to eq([])
    expect(Clearinghouse::Ledger::Invariants.check(app_db)).to eq([])
  end

  it 'reports a clearing balance that no open flow accounts for' do
    build_world
    id = app_db[:ledger_accounts].where(code: 'platform:refund_clearing', currency: 'usd').get(:id)
    owner_db[:account_balances].where(account_id: id).update(balance: 700)
    orphans = report.orphan_balances
    expect(orphans.map { |o| [o.code, o.currency, o.stored, o.open_flows_total, o.unexplained] })
      .to eq([['platform:refund_clearing', 'usd', 700, 0, 700]])
  end

  it 'nets an orphan against the open flows behind the same account, and is unhealthy for it alone' do
    flow_event('re_9', :refund, day: 0, merchant_id: 'm1', amount: usd(100))
    id = app_db[:ledger_accounts].where(code: 'platform:refund_clearing', currency: 'usd').get(:id)
    owner_db[:account_balances].where(account_id: id).update(balance: 800)
    result = described_class.report(app_db, as_of: LedgerHelpers::T0 + day, slas: slas)
    expect(result.past_sla).to eq([])
    expect(result.orphan_balances.map { |o| [o.code, o.stored, o.open_flows_total, o.unexplained] })
      .to eq([['platform:refund_clearing', 800, 100, 700]])
    expect(result).not_to be_healthy
  end

  it 'is healthy once the leak is corrected and the in-flight payment settles' do
    build_world
    leak = app_db[:ledger_transactions].where(flow_id: 'pi_4', description: 'settlement').get(:id)
    Clearinghouse::Ledger.reverse!(app_db, leak, reason: 'booked against the wrong gross', effective_at: as_of)
    flow_event('pi_4', :settlement, day: 8, gross: usd(10_000), acquirer_fee: usd(160))
    flow_event('pi_3', :settlement, day: 8, gross: usd(5000), acquirer_fee: usd(85))
    result = report
    expect(result.open_flows).to eq([])
    expect(result).to be_healthy
    expect(result.explainability.map(&:share)).to all(eq(1))
  end

  it 'lists open flow types that have no SLA instead of silently never flagging them' do
    flow_event('re_9', :refund, day: 0, merchant_id: 'm1', amount: usd(100))
    result = described_class.report(app_db, as_of: as_of, slas: {})
    expect(result.flow_types_without_sla).to eq(['refund'])
    # Flow ids that sort the other way round from their types, so the list is sorted by type.
    post(Clearinghouse::Ledger::Flows.dispute_opened(merchant_id: 'm1', amount: usd(100), fee: usd(0)),
         flow_id: 'x_2', flow_type: 'dispute')
    post(Clearinghouse::Ledger::Flows.refund(merchant_id: 'm1', amount: usd(100)), flow_id: 'x_1', flow_type: 'refund')
    expect(described_class.report(app_db, as_of: as_of, slas: {}).flow_types_without_sla).to eq(%w[dispute refund])
    expect(result.past_sla).to eq([])
    expect(result.open_flows.first.sla_seconds).to be_nil
  end

  it 'counts a flow exactly at its SLA as not yet overdue' do
    flow_event('po_9', :payout, day: 6, merchant_id: 'm1', amount: usd(100))
    expect(report.past_sla).to eq([])
    expect(described_class.report(app_db, as_of: as_of + 1, slas: slas).past_sla.map(&:flow_id)).to eq(['po_9'])
  end

  it 'counts only whole seconds of age, so a flow is not overdue until a full second past its SLA' do
    flow_event('po_9', :payout, day: 6, merchant_id: 'm1', amount: usd(100))
    expect(described_class.report(app_db, as_of: as_of + 0.5, slas: slas).past_sla).to eq([])
  end

  it 'lists open flows in byte order of flow id, whatever the database collation says' do
    # en_US collation puts pi_a before pi_B; byte order, which the report promises, does not.
    %w[pi_a pi_B].each do |id|
      flow_event(id, :capture, day: 7, merchant_id: 'm1', gross: usd(100), fee: usd(3))
    end
    expect(report.open_flows.map(&:flow_id)).to eq(%w[pi_B pi_a])
  end

  it 'reports an empty ledger as healthy with nothing to explain' do
    result = report
    expect([result.open_flows, result.orphan_balances, result.explainability]).to eq([[], [], []])
    expect(result).to be_healthy
  end

  it 'treats a flow type with no volume as fully explained' do
    empty = described_class::Explainability.new(flow_type: 'payment', currency: 'usd', flows: 0, explained_flows: 0,
                                                volume: 0, explained_volume: 0)
    expect(empty.share).to eql(Rational(1)) # a Rational like every other share, never an Integer
  end
end
