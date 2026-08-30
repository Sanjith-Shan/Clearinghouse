# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Ledger::AccountCode do
  {
    'platform:cash' => [:asset, :debit, nil],
    'platform:processor_receivable' => [:clearing, :debit, nil],
    'platform:refund_clearing' => [:clearing, :credit, nil],
    'platform:dispute_clearing' => [:clearing, :credit, nil],
    'platform:payout_clearing' => [:clearing, :credit, nil],
    'platform:fee_revenue' => [:revenue, :credit, nil],
    'platform:dispute_fee_revenue' => [:revenue, :credit, nil],
    'platform:processing_expense' => [:expense, :debit, nil],
    'platform:dispute_losses' => [:expense, :debit, nil],
    'merchant:acct_1:pending' => [:liability, :credit, 'acct_1'],
    'merchant:acct_1:available' => [:liability, :credit, 'acct_1'],
    'merchant:M9:held' => [:liability, :credit, 'M9']
  }.each do |code, (kind, side, owner)|
    it "parses #{code} as #{kind} with a #{side} normal side" do
      parsed = described_class.parse(code)
      expect([parsed.kind, parsed.normal_side, parsed.owner_id]).to eq([kind, side, owner])
      expect(parsed.clearing?).to eq(kind == :clearing)
      expect(parsed.normal_side_column).to eq(side == :debit ? 'D' : 'C')
    end
  end

  [
    'cash', 'platform:', 'platform:bank', 'platform:cash:usd', 'Platform:cash', 'merchant:m1',
    'merchant::pending', 'merchant:m1:savings', 'merchant:m-1:pending', 'merchant:m1:pending:x',
    "merchant:#{'a' * 65}:pending", ''
  ].each do |code|
    it "rejects #{code.inspect}" do
      expect { described_class.parse(code) }.to raise_error(Clearinghouse::Ledger::UnknownAccountError)
    end
  end

  it 'builds codes through the parser, so a typo cannot produce an account' do
    expect(described_class.platform('cash')).to eq('platform:cash')
    expect(described_class.merchant('m1', 'available')).to eq('merchant:m1:available')
    expect { described_class.merchant('m1', 'avail') }.to raise_error(Clearinghouse::Ledger::UnknownAccountError)
  end
end
