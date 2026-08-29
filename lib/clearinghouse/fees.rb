# typed: strict
# frozen_string_literal: true

module Clearinghouse
  # A percentage-plus-fixed fee, computed in integer arithmetic and rounded half-even.
  # The invariant that matters is gross == net + fee to the minor unit, and it holds
  # by construction because net is defined as gross minus fee.
  class FeeSchedule < T::Struct
    extend T::Sig

    # The rate is a fraction of SCALE, so 2.9% is 290_000 and the math stays integral.
    SCALE = 10_000_000

    const :rate_scaled, Integer, default: 290_000 # 2.9%
    const :fixed_minor, T::Hash[String, Integer], default: { 'usd' => 30 }

    sig { returns(FeeSchedule) }
    def self.us_card_default
      new
    end

    sig { params(gross: Money).returns(Money) }
    def fee_for(gross)
      raise ArgumentError, 'fee on a negative amount' if gross.negative?

      variable = FeeSchedule.round_half_even(gross.amount * rate_scaled, SCALE)
      Money.of(variable + fixed_minor.fetch(gross.currency, 0), gross.currency)
    end

    sig { params(gross: Money).returns([Money, Money]) }
    def split(gross)
      fee = fee_for(gross)
      [gross - fee, fee]
    end

    # Integer division rounded half to even. Both arguments non-negative.
    sig { params(numerator: Integer, denominator: Integer).returns(Integer) }
    def self.round_half_even(numerator, denominator)
      quotient, remainder = numerator.divmod(denominator)
      twice = remainder * 2
      if twice > denominator || (twice == denominator && quotient.odd?)
        quotient + 1
      else
        quotient
      end
    end
  end
end
