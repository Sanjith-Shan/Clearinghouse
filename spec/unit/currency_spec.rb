# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Currency do
  describe '.exponent and .scale' do
    # One currency per exponent class, plus the ones people get wrong.
    { 'usd' => [2, 100], 'eur' => [2, 100], 'jpy' => [0, 1], 'krw' => [0, 1],
      'kwd' => [3, 1000], 'bhd' => [3, 1000] }.each do |code, (exponent, scale)|
      it "knows #{code} has #{exponent} decimal places" do
        expect(described_class.exponent(code)).to eq(exponent)
        expect(described_class.scale(code)).to eq(scale)
      end
    end

    it 'accepts any letter case' do
      expect(described_class.exponent('JPY')).to eq(0)
      expect(described_class.scale('Kwd')).to eq(1000)
    end
  end

  describe '.normalize' do
    it 'lowercases a known code' do
      expect(described_class.normalize('USD')).to eq('usd')
    end

    it 'names the code it does not know, quoted so an empty or padded code is visible' do
      expect { described_class.normalize('xyz') }
        .to raise_error(described_class::UnknownCurrencyError, 'unknown currency "xyz"')
      expect { described_class.normalize(' usd') }
        .to raise_error(described_class::UnknownCurrencyError, 'unknown currency " usd"')
      expect { described_class.exponent('') }.to raise_error(described_class::UnknownCurrencyError, /""/)
    end
  end

  describe '.known?' do
    it 'is true for a known code in any case and false otherwise' do
      expect(described_class.known?('usd')).to be(true)
      expect(described_class.known?('KWD')).to be(true)
      expect(described_class.known?('xyz')).to be(false)
      expect(described_class.known?('')).to be(false)
    end
  end
end
