# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Payouts, '.run_scheduled!', :db do
  include PayoutHelpers

  # 2026-09-01 is a Tuesday.
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  def run
    described_class.run_scheduled!(app_db, bank: bank, clock: clock, events: events)
  end

  it "pays a daily merchant's whole available balance, once per day however often it runs" do
    merchant = new_merchant(clock: clock, payout_delay_days: 0)
    fund!(merchant, 10_000)

    first = run
    expect(first.map { |p| [p.merchant_id, p.amount.amount, p.automatic, p.status] })
      .to eq([[merchant.id, 9_680, true, 'in_transit']])
    expect(first.first.scheduled_for).to eq(Date.new(2026, 9, 1))

    fund!(merchant, 10_000) # more money the same day waits for tomorrow
    expect(run).to eq([])
    expect(app_db[:payouts].count).to eq(1)

    clock.advance(BalanceHelpers::DAY)
    expect(run.map { |p| p.amount.amount }).to eq([9_680])
    expect(merchant_balance(merchant, 'available')).to eq(0)
  end

  it 'pays each currency separately' do
    merchant = new_merchant(clock: clock, payout_delay_days: 0)
    fund!(merchant, 10_000)
    fund!(merchant, 5_000, currency: 'eur')
    expect(run.map { |p| p.amount.currency }).to contain_exactly('usd', 'eur')
  end

  it 'pays weekly merchants on Mondays only, and never pays manual ones' do
    weekly = new_merchant(clock: clock, payout_delay_days: 0, payout_interval: 'weekly')
    manual = new_merchant(clock: clock, payout_delay_days: 0, payout_interval: 'manual')
    fund!(weekly, 10_000)
    fund!(manual, 10_000)

    expect(run).to eq([])
    clock.advance_to(Time.utc(2026, 9, 7, 1)) # Monday
    expect(run.map(&:merchant_id)).to eq([weekly.id])
    expect(merchant_balance(manual, 'available')).to eq(9_680)
  end

  it 'skips balances that are zero or negative' do
    merchant = new_merchant(clock: clock, payout_delay_days: 0)
    Clearinghouse::Ledger.post!(app_db, flow_type: 'dispute', flow_id: 'dp_1', description: 'dispute opened',
                                        effective_at: clock.now,
                                        entries: Clearinghouse::Ledger::Flows.dispute_opened(
                                          merchant_id: merchant.id, amount: money(5_000), fee: money(1_500)
                                        ))
    expect(run).to eq([])
    expect(app_db[:payouts].count).to eq(0)
  end

  it 'treats a balance spent between the scan and the lock as nothing to pay' do
    merchant = new_merchant(clock: clock, payout_delay_days: 0)
    fund!(merchant, 10_000)
    allow(described_class).to receive(:reserve!).and_wrap_original do |original, *args, **kwargs|
      original.call(app_db, merchant_id: merchant.id, currency: 'usd', clock: clock) # a manual payout spends it all
      original.call(*args, **kwargs)
    end
    expect { expect(run).to eq([]) }.not_to raise_error
  end

  it 'makes one payout when several schedulers run at once' do
    merchant = new_merchant(clock: clock, payout_delay_days: 0)
    fund!(merchant, 10_000)
    made = run_concurrently(4) { run }
    expect(made.flatten.map(&:id).uniq.length).to eq(1)
    expect(app_db[:payouts].count).to eq(1)
    expect(sim.simulator.payouts.length).to eq(1)
  end
end
