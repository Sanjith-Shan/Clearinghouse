# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Ledger::Flows do
  let(:usd) { ->(amount) { Clearinghouse::Money.of(amount, 'usd') } }
  let(:events) do
    {
      capture: { merchant_id: 'm1', gross: usd[10_000], fee: usd[320] },
      settlement: { gross: usd[10_000], acquirer_fee: usd[160] },
      funds_available: { merchant_id: 'm1', net: usd[9680] },
      refund: { merchant_id: 'm1', amount: usd[4000] },
      refund_settled: { amount: usd[4000] },
      dispute_opened: { merchant_id: 'm1', amount: usd[10_000], fee: usd[1500] },
      dispute_debited: { amount: usd[10_000] },
      dispute_won: { merchant_id: 'm1', amount: usd[10_000] },
      dispute_funds_returned: { amount: usd[10_000] },
      payout: { merchant_id: 'm1', amount: usd[5000] },
      payout_paid: { amount: usd[5000] },
      payout_failed: { merchant_id: 'm1', amount: usd[5000] }
    }
  end

  def lines(entries)
    entries.map { |e| [e.side == :debit ? 'Dr' : 'Cr', e.account, e.amount.amount] }
  end

  it 'balances every event in the money-flow table' do
    events.each do |event, args|
      entries = described_class.public_send(event, **args)
      expect(entries.sum(&:signed_amount)).to eq(0), "#{event} does not balance"
      expect(entries.length).to be >= 2
    end
  end

  it 'books settlement net of the acquirer fee and clears the receivable for the gross' do
    settlement = lines(described_class.settlement(**events.fetch(:settlement)))
    expect(settlement).to eq([['Dr', 'platform:cash', 9840],
                              ['Dr', 'platform:processing_expense', 160],
                              ['Cr', 'platform:processor_receivable', 10_000]])
  end

  it 'takes the disputed amount and the fee from the merchant when a dispute opens' do
    opened = lines(described_class.dispute_opened(**events.fetch(:dispute_opened)))
    expect(opened).to eq([['Dr', 'merchant:m1:available', 10_000],
                          ['Dr', 'merchant:m1:available', 1500],
                          ['Cr', 'platform:dispute_clearing', 10_000],
                          ['Cr', 'platform:dispute_fee_revenue', 1500]])
  end

  it 'leaves out zero fee lines instead of posting a zero entry' do
    capture = described_class.capture(merchant_id: 'm1', gross: usd[500], fee: usd[0])
    settlement = described_class.settlement(gross: usd[500], acquirer_fee: usd[0])
    expect(lines(capture)).to eq([['Dr', 'platform:processor_receivable', 500], ['Cr', 'merchant:m1:pending', 500]])
    expect(lines(settlement)).to eq([['Dr', 'platform:cash', 500], ['Cr', 'platform:processor_receivable', 500]])
    opened = described_class.dispute_opened(merchant_id: 'm1', amount: usd[700], fee: usd[0])
    expect(lines(opened)).to eq([['Dr', 'merchant:m1:available', 700], ['Cr', 'platform:dispute_clearing', 700]])
  end
end
