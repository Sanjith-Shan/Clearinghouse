# typed: true
# frozen_string_literal: true

module Clearinghouse
  # Finds our own payment (or refund) from the acquirer's identifier for it. The
  # acquirer only knows its `acq_...` reference and its `op_...` operation ids;
  # disputes and the reconciler need the PaymentIntent or Refund and the merchant
  # behind it. Not scoped to a merchant: the caller is the acquirer,
  # and the answer says which merchant it is.
  module PaymentLookup
    extend T::Sig

    # What the settlement side needs to know about a payment.
    class Payment < T::Struct
      const :id, String # pi_...
      const :merchant_id, String
      const :currency, String
    end

    # A refund, found by the acquirer's id for the refund operation: the
    # `operation_id` of its settlement line.
    class Refund < T::Struct
      const :id, String # re_...
      const :payment_intent, String
      const :merchant_id, String
      const :currency, String
    end

    sig { params(db: Sequel::Database, acquirer_reference: String).returns(T.nilable(Payment)) }
    def self.by_acquirer_reference(db, acquirer_reference)
      row = db[:payment_intents].where(acquirer_reference: acquirer_reference)
                                .select(:id, :merchant_id, :currency).first
      row ? Payment.new(id: row.fetch(:id), merchant_id: row.fetch(:merchant_id), currency: row.fetch(:currency)) : nil
    end

    # Refunds record the acquirer's operation id when the acquirer approves them.
    sig { params(db: Sequel::Database, operation_id: String).returns(T.nilable(Refund)) }
    def self.refund_by_acquirer_operation(db, operation_id)
      row = db[:refunds].where(acquirer_operation_id: operation_id)
                        .select(:id, :payment_intent_id, :merchant_id, :currency).first
      return nil unless row

      Refund.new(id: row.fetch(:id), payment_intent: row.fetch(:payment_intent_id),
                 merchant_id: row.fetch(:merchant_id), currency: row.fetch(:currency))
    end
  end
end
