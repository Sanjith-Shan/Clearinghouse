# typed: strict
# frozen_string_literal: true

module Clearinghouse
  # An amount in integer minor units of one currency. There is no Float path in or
  # out of this type on purpose.
  class Money < T::Struct
    extend T::Sig
    include Comparable

    class CurrencyMismatchError < Clearinghouse::Error; end

    const :amount, Integer
    const :currency, String

    sig { params(amount: Integer, currency: String).returns(Money) }
    def self.of(amount, currency)
      new(amount: amount, currency: Currency.normalize(currency)).freeze
    end

    sig { params(currency: String).returns(Money) }
    def self.zero(currency)
      of(0, currency)
    end

    # Parses a decimal string like "12.34" in the currency's own exponent. Rejects
    # more fractional digits than the currency has rather than rounding them away.
    sig { params(text: String, currency: String).returns(Money) }
    def self.parse(text, currency)
      exponent = Currency.exponent(currency)
      match = /\A(-)?(\d+)(?:\.(\d+))?\z/.match(text)
      raise ArgumentError, "not a decimal amount: #{text.inspect}" unless match

      fraction = match[3] || ''
      raise ArgumentError, "#{text} has more than #{exponent} decimal places" if fraction.length > exponent

      padded = fraction.ljust(exponent, '0')
      minor = (Integer(T.must(match[2]), 10) * Currency.scale(currency)) + (padded.empty? ? 0 : Integer(padded, 10))
      of(match[1] ? -minor : minor, currency)
    end

    sig { params(other: Money).returns(Money) }
    def +(other)
      Money.of(amount + same_currency!(other).amount, currency)
    end

    sig { params(other: Money).returns(Money) }
    def -(other)
      Money.of(amount - same_currency!(other).amount, currency)
    end

    sig { returns(Money) }
    def -@
      Money.of(-amount, currency)
    end

    sig { params(other: T.untyped).returns(T.nilable(Integer)) }
    def <=>(other)
      return nil unless other.is_a?(Money) && other.currency == currency

      amount <=> other.amount
    end

    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      return false unless other.is_a?(Money)

      other.currency == currency && other.amount == amount
    end
    alias eql? ==

    sig { returns(Integer) }
    def hash
      [amount, currency].hash
    end

    sig { returns(T::Boolean) }
    def zero?
      amount.zero?
    end

    sig { returns(T::Boolean) }
    def negative?
      amount.negative?
    end

    sig { returns(T::Boolean) }
    def positive?
      amount.positive?
    end

    # "12.34 USD", "1234 JPY", "1.234 KWD".
    sig { returns(String) }
    def to_s
      exponent = Currency.exponent(currency)
      sign = amount.negative? ? '-' : ''
      whole, fraction = amount.abs.divmod(Currency.scale(currency))
      body = exponent.zero? ? whole.to_s : "#{whole}.#{fraction.to_s.rjust(exponent, '0')}"
      "#{sign}#{body} #{currency.upcase}"
    end

    private

    sig { params(other: Money).returns(Money) }
    def same_currency!(other)
      raise CurrencyMismatchError, "#{currency} vs #{other.currency}" unless other.currency == currency

      other
    end
  end
end
