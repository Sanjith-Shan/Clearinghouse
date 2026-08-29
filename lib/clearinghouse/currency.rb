# typed: strict
# frozen_string_literal: true

module Clearinghouse
  # ISO 4217 minor-unit exponents. Getting this wrong is the classic payments bug:
  # 100 JPY is one hundred yen, not one yen, and 1000 KWD minor units is one dinar.
  module Currency
    extend T::Sig

    class UnknownCurrencyError < Clearinghouse::Error; end

    EXPONENTS = T.let(
      {
        'usd' => 2, 'eur' => 2, 'gbp' => 2, 'cad' => 2, 'aud' => 2, 'inr' => 2, 'chf' => 2,
        'jpy' => 0, 'krw' => 0, 'vnd' => 0, 'clp' => 0,
        'kwd' => 3, 'bhd' => 3, 'jod' => 3, 'omr' => 3, 'tnd' => 3
      }.freeze,
      T::Hash[String, Integer]
    )

    sig { params(code: String).returns(String) }
    def self.normalize(code)
      normalized = code.downcase
      raise UnknownCurrencyError, "unknown currency #{code.inspect}" unless EXPONENTS.key?(normalized)

      normalized
    end

    sig { params(code: String).returns(Integer) }
    def self.exponent(code)
      EXPONENTS.fetch(normalize(code))
    end

    # 10 ** exponent, the number of minor units in one major unit.
    sig { params(code: String).returns(Integer) }
    def self.scale(code)
      T.cast(10**exponent(code), Integer)
    end

    sig { params(code: String).returns(T::Boolean) }
    def self.known?(code)
      EXPONENTS.key?(code.downcase)
    end
  end
end
