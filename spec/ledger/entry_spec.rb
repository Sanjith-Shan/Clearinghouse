# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Ledger::Entry do
  let(:amount) { Clearinghouse::Money.of(500, 'usd') }

  it 'builds entries on the two sides the ledger accepts' do
    expect(described_class.debit('platform:cash', amount).side).to eq(:debit)
    expect(described_class.credit('platform:cash', amount).side).to eq(:credit)
    expect(described_class::SIDES).to eq(%i[debit credit])
  end

  it 'signs debits positive and credits negative' do
    expect(described_class.debit('platform:cash', amount).signed_amount).to eq(500)
    expect(described_class.credit('platform:cash', amount).signed_amount).to eq(-500)
  end

  it 'flips sides and keeps everything else' do
    flipped = described_class.debit('platform:cash', amount).flipped
    expect([flipped.account, flipped.side, flipped.amount]).to eq(['platform:cash', :credit, amount])
    expect(flipped.flipped.side).to eq(:debit)
  end

  it 'maps sides to and from the stored column' do
    expect(described_class.debit('platform:cash', amount).side_column).to eq('D')
    expect(described_class.credit('platform:cash', amount).side_column).to eq('C')
    expect(described_class.side_from_column('D')).to eq(:debit)
    expect(described_class.side_from_column('C')).to eq(:credit)
  end
end
