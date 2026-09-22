# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Money do
  let(:g) { PropCheck::Generators }

  def money(amount, currency = 'usd')
    described_class.of(amount, currency)
  end

  describe 'currency exponents' do
    {
      'usd' => ['12.34', 1234, '12.34 USD'],
      'jpy' => ['1234', 1234, '1234 JPY'],
      'krw' => ['50000', 50_000, '50000 KRW'],
      'kwd' => ['1.234', 1234, '1.234 KWD'],
      'bhd' => ['0.005', 5, '0.005 BHD']
    }.each do |currency, (text, minor, rendered)|
      it "parses and renders #{currency} with its own exponent" do
        parsed = described_class.parse(text, currency)
        expect(parsed.amount).to eq(minor)
        expect(parsed.to_s).to eq(rendered)
      end
    end

    it 'rejects a fraction on a zero-decimal currency instead of rounding it' do
      expect { described_class.parse('100.5', 'jpy') }.to raise_error(ArgumentError, /more than 0 decimal places/)
    end

    it 'rejects a fourth decimal on a three-decimal currency' do
      expect { described_class.parse('1.2345', 'kwd') }.to raise_error(ArgumentError)
    end

    it 'pads short fractions' do
      expect(described_class.parse('1.5', 'kwd').amount).to eq(1500)
      expect(described_class.parse('7', 'usd').amount).to eq(700)
    end

    it 'parses and renders negatives' do
      expect(described_class.parse('-0.05', 'usd').amount).to eq(-5)
      expect(money(-5).to_s).to eq('-0.05 USD')
    end

    it 'rejects junk and floats in scientific notation, quoting the input' do
      ['1e3', '', '1.2.3', 'abc', ' 1'].each do |junk|
        expect { described_class.parse(junk, 'usd') }
          .to raise_error(ArgumentError, "not a decimal amount: #{junk.inspect}")
      end
    end

    it 'says which amount had too many decimal places for which exponent' do
      expect { described_class.parse('1.2345', 'kwd') }
        .to raise_error(ArgumentError, '1.2345 has more than 3 decimal places')
    end

    it 'reads leading zeros as decimal, never octal' do
      expect(described_class.parse('010.50', 'usd').amount).to eq(1050)
      expect(described_class.parse('09', 'jpy').amount).to eq(9)
    end

    it 'rejects unknown currencies' do
      expect { money(1, 'xyz') }.to raise_error(Clearinghouse::Currency::UnknownCurrencyError)
    end

    it 'normalizes case' do
      expect(money(1, 'USD').currency).to eq('usd')
    end

    it 'builds a zero in any known currency' do
      zero = described_class.zero('JPY')
      expect([zero.amount, zero.currency, zero.frozen?]).to eq([0, 'jpy', true])
      expect { described_class.zero('xyz') }.to raise_error(Clearinghouse::Currency::UnknownCurrencyError)
    end
  end

  describe 'arithmetic' do
    it 'adds, subtracts and negates within one currency' do
      expect(money(100) + money(25)).to eq(money(125))
      expect(money(100) - money(125)).to eq(money(-25))
      expect(-money(7)).to eq(money(-7))
    end

    it 'raises when currencies are mixed, naming both' do
      expect { money(1, 'usd') + money(1, 'eur') }.to raise_error(described_class::CurrencyMismatchError, 'usd vs eur')
      expect { money(1, 'usd') - money(1, 'jpy') }.to raise_error(described_class::CurrencyMismatchError, 'usd vs jpy')
    end

    it 'is equal only to Money of the same amount and currency' do
      expect(money(1)).not_to eq(money(2))
      expect(money(1) == 1).to be(false)
      expect(money(0) == nil).to be(false) # rubocop:disable Style/NilComparison
      expect(money(1).eql?(money(2))).to be(false)
    end

    it 'spreads distinct values over distinct hashes, so it works as a hash key at scale' do
      values = [money(1), money(2), money(1, 'eur'), money(0, 'jpy'), money(-1)]
      expect(values.map(&:hash).uniq.length).to eq(values.length)
    end

    it 'does not compare across currencies' do
      expect(money(1, 'usd') <=> money(1, 'eur')).to be_nil
      expect(money(1, 'usd')).not_to eq(money(1, 'eur'))
      expect(money(1) <=> 1).to be_nil
    end

    it 'orders and hashes by value' do
      expect(money(1)).to be < money(2)
      expect({ money(3) => :x }[money(3)]).to eq(:x)
      expect(money(3).eql?(money(1) + money(2))).to be(true)
    end

    it 'reports sign' do
      expect([money(0).zero?, money(1).positive?, money(-1).negative?]).to eq([true, true, true])
      expect([money(1).zero?, money(0).positive?, money(0).negative?]).to eq([false, false, false])
    end

    it 'is frozen' do
      expect(money(1)).to be_frozen
    end

    it 'keeps addition associative and invertible over random amounts' do
      amounts = g.integer
      PropCheck.forall(a: amounts, b: amounts, c: amounts) do |a:, b:, c:|
        expect((money(a) + money(b)) + money(c)).to eq(money(a) + (money(b) + money(c)))
        expect((money(a) + money(b)) - money(b)).to eq(money(a))
      end
    end

    it 'round-trips through to_s and parse for every exponent' do
      currencies = g.one_of(*%w[usd jpy kwd].map { |c| g.constant(c) })
      PropCheck.forall(amount: g.integer, currency: currencies) do |amount:, currency:|
        m = money(amount, currency)
        expect(described_class.parse(m.to_s.split.first, currency)).to eq(m)
      end
    end
  end
end
