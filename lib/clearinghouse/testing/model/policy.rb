# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # The numbers and rules the reference model encodes. The policies come from
      # docs/design/ledger.md and the simulator's behaviour from docs/design/sim.md.
      # Where neither says, the choice is written up in docs/design/model-testing.md
      # under "Interpretations", and each such constant says so.
      module Policy
        extend T::Sig

        START = Time.utc(2026, 1, 1)
        HOUR = 3600
        DAY = 86_400

        CURRENCIES = %w[usd jpy kwd].freeze

        # The simulator's defaults (docs/design/sim.md).
        SETTLEMENT_LAG_DAYS = 2
        DISPUTE_AFTER_DAYS = 7
        PAYOUT_ARRIVAL_SECONDS = DAY
        ACQUIRER_RATE_SCALED = 150_000 # 1.5%
        ACQUIRER_FIXED_MINOR = 10

        # Interpretation: funds become available payout_delay_days (the merchant
        # default, 2) after capture, like Stripe's available_on, whether or not the
        # settlement line has arrived.
        PAYOUT_DELAY_DAYS = 2

        # Interpretation: the ledger doc prices the dispute fee at $15.00 and says
        # nothing for other currencies.
        DISPUTE_FEE = T.let({ 'usd' => 1500, 'jpy' => 1500, 'kwd' => 5000 }.freeze, T::Hash[String, Integer])

        # Payments refuses an amount smaller than our fee on it (amount_too_small), at
        # create and at capture, so the merchant's share is never negative
        # (docs/design/payments.md). With the default fee that is 31 cents.
        sig { params(amount: Integer, rate_scaled: Integer, fixed: Integer).returns(T::Boolean) }
        def self.covers_fee?(amount, rate_scaled, fixed)
          fee(amount, rate_scaled, fixed) <= amount
        end

        # How long an authorization waits for capture before the expiry sweep
        # cancels it (Api::Dependencies#authorization_ttl_days).
        AUTHORIZATION_TTL_DAYS = 7

        APPROVING_CARDS = %w[pm_card_visa pm_card_mastercard pm_card_disputeFraudulent pm_card_timeout].freeze
        DECLINING_CARDS = T.let({
          'pm_card_chargeDeclined' => 'generic_decline',
          'pm_card_insufficientFunds' => 'insufficient_funds',
          'pm_card_expired' => 'expired_card'
        }.freeze, T::Hash[String, String])
        # The error code of each decline. An expired card has its own code, as in
        # Stripe's API; the others are card_declined (Payments::Errors::DECLINES).
        DECLINE_ERROR_CODES = T.let({ 'expired_card' => 'expired_card' }.freeze, T::Hash[String, String])
        DISPUTING_CARD = 'pm_card_disputeFraudulent'

        FEE_SCALE = 10_000_000

        # The simulator fails a payout whose amount in minor units ends in 13
        # (AcquirerSim::Simulator.payout_fails?).
        sig { params(amount: Integer).returns(T::Boolean) }
        def self.payout_fails?(amount)
          amount % 100 == 13
        end

        # Percentage plus fixed, rounded half-even. Written with Rational rather than
        # by calling FeeSchedule, so a rounding bug in FeeSchedule shows up as a
        # difference instead of being copied into the expectation.
        sig { params(gross: Integer, rate_scaled: Integer, fixed: Integer).returns(Integer) }
        def self.fee(gross, rate_scaled, fixed)
          exact = Rational(gross * rate_scaled, FEE_SCALE)
          whole = exact.floor
          fraction = exact - whole
          rounded = if fraction == Rational(1, 2) then whole.even? ? whole : whole + 1
                    elsif fraction > Rational(1, 2) then whole + 1
                    else whole
                    end
          rounded + fixed
        end

        # The simulator's fixed part is the same count of minor units in every currency.
        sig { params(gross: Integer).returns(Integer) }
        def self.acquirer_fee(gross)
          fee(gross, ACQUIRER_RATE_SCALED, ACQUIRER_FIXED_MINOR)
        end
      end
    end
  end
end
