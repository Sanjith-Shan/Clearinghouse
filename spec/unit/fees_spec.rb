# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::FeeSchedule do
  let(:schedule) { described_class.us_card_default }

  def usd(amount)
    Clearinghouse::Money.of(amount, 'usd')
  end

  it 'charges 2.9% + 30c on $100' do
    expect(schedule.split(usd(10_000))).to eq([usd(9_680), usd(320)])
  end

  it 'rounds half to even' do
    expect(described_class.round_half_even(25, 10)).to eq(2)
    expect(described_class.round_half_even(35, 10)).to eq(4)
    expect(described_class.round_half_even(26, 10)).to eq(3)
    expect(described_class.round_half_even(24, 10)).to eq(2)
    expect(described_class.round_half_even(20, 10)).to eq(2)
  end

  it 'rounds an exact half-cent tie to even' do
    # 2.9% of 500 cents is 14.5 cents, which rounds to 14, not 15.
    expect(schedule.fee_for(usd(500))).to eq(usd(44))
    # 2.9% of 50 cents is 1.45 cents, below the tie, so 1.
    expect(schedule.fee_for(usd(50))).to eq(usd(31))
  end

  it 'has no fixed fee in a currency the schedule does not name' do
    expect(schedule.fee_for(Clearinghouse::Money.of(10_000, 'jpy'))).to eq(Clearinghouse::Money.of(290, 'jpy'))
  end

  it 'refuses negative amounts' do
    expect { schedule.fee_for(usd(-1)) }.to raise_error(ArgumentError, 'fee on a negative amount')
  end

  it 'keeps gross == net + fee to the minor unit for random amounts and rates' do
    g = PropCheck::Generators
    PropCheck.forall(amount: g.nonnegative_integer, rate: g.choose(0..described_class::SCALE),
                     fixed: g.choose(0..500)) do |amount:, rate:, fixed:|
      custom = described_class.new(rate_scaled: rate, fixed_minor: { 'usd' => fixed })
      net, fee = custom.split(usd(amount))
      expect(net + fee).to eq(usd(amount))
      exact = Rational(amount * rate, described_class::SCALE)
      expect((fee.amount - fixed - exact).abs).to be <= Rational(1, 2)
    end
  end
end
