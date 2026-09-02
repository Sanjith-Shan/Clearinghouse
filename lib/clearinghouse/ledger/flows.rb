# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    # The money-flow table in docs/design/ledger.md, as code. Each method returns
    # the entries for one event and posts nothing; the caller posts them with
    # Ledger.post! inside the transaction that changes the domain object, under
    # the flow id of that object (pi_, re_, dp_, po_) and the flow type below.
    #
    # Keeping the entries here, rather than spread across payments, refunds,
    # disputes and payouts, means the table and the code cannot drift apart
    # without a test noticing.
    module Flows
      extend T::Sig

      PAYMENT = 'payment'
      REFUND = 'refund'
      DISPUTE = 'dispute'
      PAYOUT = 'payout'

      CASH = 'platform:cash'
      RECEIVABLE = 'platform:processor_receivable'
      REFUND_CLEARING = 'platform:refund_clearing'
      DISPUTE_CLEARING = 'platform:dispute_clearing'
      PAYOUT_CLEARING = 'platform:payout_clearing'
      FEE_REVENUE = 'platform:fee_revenue'
      DISPUTE_FEE_REVENUE = 'platform:dispute_fee_revenue'
      PROCESSING_EXPENSE = 'platform:processing_expense'

      # Payment captured. We are owed the gross by the acquirer, owe the merchant
      # the net once it is available, and have earned our fee.
      sig { params(merchant_id: String, gross: Money, fee: Money).returns(T::Array[Entry]) }
      def self.capture(merchant_id:, gross:, fee:)
        present([Entry.debit(RECEIVABLE, gross),
                 Entry.credit(AccountCode.merchant(merchant_id, 'pending'), gross - fee),
                 Entry.credit(FEE_REVENUE, fee)])
      end

      # Settlement file line for a capture. The acquirer pays gross minus its own
      # processing fee; the receivable clears for the full gross.
      sig { params(gross: Money, acquirer_fee: Money).returns(T::Array[Entry]) }
      def self.settlement(gross:, acquirer_fee:)
        present([Entry.debit(CASH, gross - acquirer_fee),
                 Entry.debit(PROCESSING_EXPENSE, acquirer_fee),
                 Entry.credit(RECEIVABLE, gross)])
      end

      # The settlement delay has passed; the merchant's net can be paid out.
      sig { params(merchant_id: String, net: Money).returns(T::Array[Entry]) }
      def self.funds_available(merchant_id:, net:)
        [Entry.debit(AccountCode.merchant(merchant_id, 'pending'), net),
         Entry.credit(AccountCode.merchant(merchant_id, 'available'), net)]
      end

      # Refund issued. Our fee is not returned (docs/design/ledger.md).
      sig { params(merchant_id: String, amount: Money).returns(T::Array[Entry]) }
      def self.refund(merchant_id:, amount:)
        [Entry.debit(AccountCode.merchant(merchant_id, 'available'), amount),
         Entry.credit(REFUND_CLEARING, amount)]
      end

      # Settlement file line for the refund: the acquirer takes the cash back.
      sig { params(amount: Money).returns(T::Array[Entry]) }
      def self.refund_settled(amount:)
        [Entry.debit(REFUND_CLEARING, amount), Entry.credit(CASH, amount)]
      end

      # Dispute opened. The merchant's available balance is debited for the
      # disputed amount and the dispute fee, and may go negative.
      sig { params(merchant_id: String, amount: Money, fee: Money).returns(T::Array[Entry]) }
      def self.dispute_opened(merchant_id:, amount:, fee:)
        available = AccountCode.merchant(merchant_id, 'available')
        present([Entry.debit(available, amount), Entry.debit(available, fee),
                 Entry.credit(DISPUTE_CLEARING, amount), Entry.credit(DISPUTE_FEE_REVENUE, fee)])
      end

      # The acquirer withdraws the disputed amount from us (a `dispute` settlement
      # line). For a lost dispute this is the last step.
      sig { params(amount: Money).returns(T::Array[Entry]) }
      def self.dispute_debited(amount:)
        [Entry.debit(DISPUTE_CLEARING, amount), Entry.credit(CASH, amount)]
      end

      # Dispute won. The merchant gets the amount back; the fee is kept.
      sig { params(merchant_id: String, amount: Money).returns(T::Array[Entry]) }
      def self.dispute_won(merchant_id:, amount:)
        [Entry.debit(DISPUTE_CLEARING, amount), Entry.credit(AccountCode.merchant(merchant_id, 'available'), amount)]
      end

      # The acquirer returns the disputed amount after a win (a
      # `dispute_reversal` settlement line).
      sig { params(amount: Money).returns(T::Array[Entry]) }
      def self.dispute_funds_returned(amount:)
        [Entry.debit(CASH, amount), Entry.credit(DISPUTE_CLEARING, amount)]
      end

      sig { params(merchant_id: String, amount: Money).returns(T::Array[Entry]) }
      def self.payout(merchant_id:, amount:)
        [Entry.debit(AccountCode.merchant(merchant_id, 'available'), amount), Entry.credit(PAYOUT_CLEARING, amount)]
      end

      sig { params(amount: Money).returns(T::Array[Entry]) }
      def self.payout_paid(amount:)
        [Entry.debit(PAYOUT_CLEARING, amount), Entry.credit(CASH, amount)]
      end

      # The bank rejected the payout; the money goes back to the merchant.
      sig { params(merchant_id: String, amount: Money).returns(T::Array[Entry]) }
      def self.payout_failed(merchant_id:, amount:)
        [Entry.debit(PAYOUT_CLEARING, amount), Entry.credit(AccountCode.merchant(merchant_id, 'available'), amount)]
      end

      # A zero fee is a real case (a fee-free merchant, a zero acquirer fee), and
      # a zero entry is not allowed, so the line is simply left out.
      sig { params(entries: T::Array[Entry]).returns(T::Array[Entry]) }
      def self.present(entries)
        entries.reject { |e| e.amount.zero? }
      end
      private_class_method :present
    end
  end
end
