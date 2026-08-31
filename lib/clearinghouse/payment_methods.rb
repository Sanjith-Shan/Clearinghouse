# typed: strict
# frozen_string_literal: true

module Clearinghouse
  # The test payment methods. There are no real cards anywhere in Clearinghouse:
  # a payment method is one of these tokens, and its behaviour at the acquirer
  # simulator follows the token. The last4 values follow Stripe's published test
  # card numbers where one exists for the behaviour.
  module PaymentMethods
    extend T::Sig

    CARDS = T.let({
      'pm_card_visa' => %w[visa 4242],
      'pm_card_mastercard' => %w[mastercard 4444],
      'pm_card_chargeDeclined' => %w[visa 0002],
      'pm_card_insufficientFunds' => %w[visa 9995],
      'pm_card_expired' => %w[visa 0069],
      'pm_card_disputeFraudulent' => %w[visa 0259],
      'pm_card_timeout' => %w[visa 0119]
    }.freeze, T::Hash[String, [String, String]])

    sig { params(id: String).returns(T::Boolean) }
    def self.known?(id) = CARDS.key?(id)

    # The PaymentMethod object, or nil for an unknown token.
    sig { params(id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def self.to_api(id)
      brand, last4 = CARDS[id]
      return nil unless brand

      { 'id' => id, 'object' => 'payment_method', 'type' => 'card', 'card' => { 'brand' => brand, 'last4' => last4 } }
    end
  end
end
