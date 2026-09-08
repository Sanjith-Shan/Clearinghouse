# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Disputes
    # The dispute fee we charge the merchant when a dispute opens, per currency.
    #
    # The spec asks for 15.00 USD "or equivalent". There is no FX in Clearinghouse (the
    # spec rules it out), so the fee is not converted at a rate. Each currency has its
    # own fixed price, a round local number near 15 USD, in that currency's minor
    # units: 15.00 USD, 2200 JPY, 4.600 KWD. The table covers every currency in
    # Currency::EXPONENTS, and a currency without a price raises instead of charging
    # nothing, so adding a currency forces a pricing decision. The prices are rough
    # 2026 equivalents and a real platform would set them in its pricing contract.
    #
    # The fee is kept when the dispute is won (docs/design/ledger.md).
    class FeePolicy < T::Struct
      extend T::Sig

      class UnpricedCurrencyError < Clearinghouse::Error; end

      DEFAULT_FEES = T.let({
        'usd' => 1_500, 'eur' => 1_500, 'gbp' => 1_200, 'cad' => 2_000, 'aud' => 2_200, 'chf' => 1_300,
        'inr' => 130_000, 'jpy' => 2_200, 'krw' => 20_000, 'vnd' => 380_000, 'clp' => 14_000,
        'kwd' => 4_600, 'bhd' => 5_650, 'jod' => 10_650, 'omr' => 5_800, 'tnd' => 45_000
      }.freeze, T::Hash[String, Integer])

      const :fees, T::Hash[String, Integer], default: DEFAULT_FEES

      sig { params(currency: String).returns(Money) }
      def fee_for(currency)
        code = Currency.normalize(currency)
        Money.of(fees.fetch(code) { raise UnpricedCurrencyError, "no dispute fee is set for #{code}" }, code)
      end
    end
  end
end
