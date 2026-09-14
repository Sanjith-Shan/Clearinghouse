# typed: false
# frozen_string_literal: true

# The negative-balance policy (docs/design/payouts.md), with the dispute and refund
# debits posted at the ledger level through Ledger::Flows, as the disputes and
# payments areas will post them.
RSpec.describe Clearinghouse::Payouts, '.reserve! with a negative available balance', :db do
  include PayoutHelpers

  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { new_merchant(clock: clock, payout_delay_days: 0) }
  let(:flows) { Clearinghouse::Ledger::Flows }

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  def dispute!(amount, fee: 1_500)
    Clearinghouse::Ledger.post!(app_db, flow_type: 'dispute', flow_id: Clearinghouse::Ids.generate('dp'),
                                        description: 'dispute opened', effective_at: clock.now,
                                        entries: flows.dispute_opened(merchant_id: merchant.id, amount: money(amount),
                                                                      fee: money(fee)))
  end

  def payout!(amount: nil)
    Clearinghouse::Payouts.create!(app_db, merchant_id: merchant.id, currency: 'usd', bank: bank, clock: clock,
                                           amount: amount)
  end

  it 'lets a dispute take available below zero, blocks payouts, and lets later captures pay it down' do
    fund!(merchant, 10_000)                   # available 96.80
    payout!                                   # paid out: available 0.00
    dispute!(10_000)                          # 100.00 + 15.00 fee: available -115.00
    expect(merchant_balance(merchant, 'available')).to eq(-11_500)
    expect { payout!(amount: 1) }.to raise_error(Clearinghouse::Payouts::BalanceInsufficientError, /-115.00 USD/)

    fund!(merchant, 10_000)                   # +96.80: available -18.20, still blocked
    expect(merchant_balance(merchant, 'available')).to eq(-1_820)
    expect { payout! }.to raise_error(Clearinghouse::Payouts::BalanceInsufficientError)

    fund!(merchant, 5_000)                    # +48.25: available 30.05
    expect(payout!.amount).to eq(money(3_005)) # only what is left after the debt
    expect(merchant_balance(merchant, 'available')).to eq(0)
  end

  it 'blocks at exactly zero too' do
    fund!(merchant, 10_000)
    dispute!(8_180) # 81.80 + 15.00 = 96.80
    expect(merchant_balance(merchant, 'available')).to eq(0)
    expect { payout! }.to raise_error(Clearinghouse::Payouts::BalanceInsufficientError, /nothing to pay out/)
  end

  it 'treats a refund past the available balance the same way' do
    fund!(merchant, 10_000)
    payout!
    Clearinghouse::Ledger.post!(app_db, flow_type: 'refund', flow_id: Clearinghouse::Ids.generate('re'),
                                        description: 'refund', effective_at: clock.now,
                                        entries: flows.refund(merchant_id: merchant.id, amount: money(4_000)))
    expect(merchant_balance(merchant, 'available')).to eq(-4_000)
    expect { payout! }.to raise_error(Clearinghouse::Payouts::BalanceInsufficientError)
  end

  it 'does not count held money towards paying the debt, and counts it once the review is approved' do
    reviewed, = capture!(merchant, 10_000, clock: clock)
    hold = Clearinghouse::Balances::Holds.open_hold!(app_db, flow_id: reviewed, merchant_id: merchant.id,
                                                             amount: money(10_000), reason: 'rule', clock: clock)
    Clearinghouse::Balances::Availability.release_due!(app_db, clock: clock)
    dispute!(3_000) # available -45.00, held 96.80
    expect { payout! }.to raise_error(Clearinghouse::Payouts::BalanceInsufficientError)

    Clearinghouse::Balances::Holds.close_hold!(app_db, hold.id, merchant_id: merchant.id, decision: :approve,
                                                                clock: clock)
    expect(merchant_balance(merchant, 'available')).to eq(5_180)
    expect(payout!.amount).to eq(money(5_180))
  end

  it 'makes a dispute and a payout racing for the same balance serialize on the balance row' do
    fund!(merchant, 10_000)
    payout, = run_concurrently(2) { |i| i.zero? ? payout! : dispute!(5_000) }
    # Either the payout locked first and took 96.80, then the dispute took the balance
    # to -65.00; or the dispute went first and the payout took the 31.80 left.
    outcomes = { 9_680 => -6_500, 3_180 => 0 }
    expect(outcomes).to include(payout.amount.amount => merchant_balance(merchant, 'available'))
  end
end
