# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Disputes
    # A chargeback on one payment. `needs_response` until the acquirer rules or the
    # merchant accepts the loss; then `won` or `lost`.
    class Dispute < T::Struct
      extend T::Sig

      STATUSES = %w[needs_response won lost].freeze

      const :id, String
      const :merchant_id, String
      const :payment_intent, String
      const :amount, Money
      const :fee, Money
      const :reason, String
      const :status, String
      const :closed_by, T.nilable(String)
      const :acquirer_dispute_id, String
      const :acquirer_reference, String
      const :opened_transaction_id, Integer
      const :won_transaction_id, T.nilable(Integer)
      const :created_at, Time
      const :closed_at, T.nilable(Time)

      # The latest-version API shape. The first seven fields are the contract with
      # RiskGate, which reads charge.dispute.* events as fraud labels
      # (docs/design/interfaces.md); the versioning engine refuses to let a version
      # change touch them.
      sig { returns(T::Hash[String, T.untyped]) }
      def to_api
        {
          'id' => id,
          'object' => 'dispute',
          'payment_intent' => payment_intent,
          'amount' => amount.amount,
          'currency' => amount.currency,
          'reason' => reason,
          'status' => status,
          'fee' => fee.amount,
          'created' => created_at.to_i,
          'livemode' => false
        }
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(Dispute) }
      def self.from_row(row)
        currency = row.fetch(:currency)
        new(id: row.fetch(:id), merchant_id: row.fetch(:merchant_id), payment_intent: row.fetch(:payment_intent),
            amount: Money.of(Integer(row.fetch(:amount)), currency), fee: Money.of(Integer(row.fetch(:fee)), currency),
            reason: row.fetch(:reason), status: row.fetch(:status), closed_by: row[:closed_by],
            acquirer_dispute_id: row.fetch(:acquirer_dispute_id), acquirer_reference: row.fetch(:acquirer_reference),
            opened_transaction_id: Integer(row.fetch(:opened_transaction_id)),
            won_transaction_id: row[:won_transaction_id]&.then { |v| Integer(v) },
            created_at: row.fetch(:created_at).utc, closed_at: row[:closed_at]&.utc)
      end
    end
  end
end
