# typed: true
# frozen_string_literal: true

module Clearinghouse
  # Finds our own payment from the acquirer's identifier for it. The acquirer only
  # knows its `acq_...` reference; disputes and the reconciler need the PaymentIntent
  # and the merchant behind it.
  #
  # This is a seam. PaymentIntents (with their `acquirer_reference` column) belong to
  # the payments work, which is not on main yet. Code here depends only on this
  # interface; the implementation over the payment_intents table plugs in when that
  # lands, and specs use the in-memory stand-in in spec/support.
  module PaymentLookup
    extend T::Sig
    extend T::Helpers

    interface!

    # What the settlement side needs to know about a payment.
    class Payment < T::Struct
      const :id, String # pi_...
      const :merchant_id, String
      const :currency, String
    end

    sig { abstract.params(db: Sequel::Database, acquirer_reference: String).returns(T.nilable(Payment)) }
    def by_acquirer_reference(db, acquirer_reference); end
  end
end
