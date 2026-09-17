# typed: true
# frozen_string_literal: true

module Clearinghouse
  # Finds our own payment from the acquirer's identifier for it. The acquirer only
  # knows its `acq_...` reference; disputes and the reconciler need the PaymentIntent
  # and the merchant behind it. Not scoped to a merchant: the caller is the acquirer,
  # and the answer says which merchant it is.
  module PaymentLookup
    extend T::Sig

    # What the settlement side needs to know about a payment.
    class Payment < T::Struct
      const :id, String # pi_...
      const :merchant_id, String
      const :currency, String
    end

    sig { params(db: Sequel::Database, acquirer_reference: String).returns(T.nilable(Payment)) }
    def self.by_acquirer_reference(db, acquirer_reference)
      row = db[:payment_intents].where(acquirer_reference: acquirer_reference)
                                .select(:id, :merchant_id, :currency).first
      row ? Payment.new(id: row.fetch(:id), merchant_id: row.fetch(:merchant_id), currency: row.fetch(:currency)) : nil
    end
  end
end
