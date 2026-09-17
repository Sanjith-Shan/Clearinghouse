# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Reconciliation
    # Finds the flow a settlement line belongs to and what the line should say.
    #
    # The expectation comes from our own books, never from the line: the amount is the
    # one our ledger moved into clearing (the capture's receivable, the refund's
    # refund_clearing, the dispute's amount) and the fee is the acquirer's contract
    # applied to that amount. So a line that disagrees with the ledger is found by
    # comparing it with the ledger, which is the only definition of "wrong" that does
    # not trust the file.
    class Matcher
      extend T::Sig

      # The flow a line settles and what the line should say.
      class Target < T::Struct
        const :flow_id, String
        const :flow_type, String
        const :merchant_id, String
        const :payment_intent, String
        const :clearing_account, String
        # Signed the way the acquirer writes it: captures and reversals positive,
        # refunds and disputes negative.
        const :expected_amount, Integer
        const :expected_fee, Integer
        const :currency, String
        # When the movement happened, in simulated time (the ledger's effective_at), and
        # when we recorded it, by the database clock (ledger_transactions.created_at).
        const :happened_at, Time
        const :recorded_at, Time
      end

      # No flow for the line. `pending` lines may still match: the flow is one we
      # expect to learn about (a dispute whose notification the poller has not handled
      # yet). The rest are `unknown_payment` exceptions.
      class Unmatched < T::Struct
        const :pending, T::Boolean
        const :detail, String
      end

      FIRST_POSTING = <<~SQL
        SELECT t.id, t.effective_at, t.created_at, e.amount, e.currency
          FROM ledger_transactions t
          JOIN ledger_entries e ON e.transaction_id = t.id
          JOIN ledger_accounts a ON a.id = e.account_id
         WHERE t.flow_id = ? AND a.code = ? AND e.side = ?
         ORDER BY t.effective_at, t.id
         LIMIT 1
      SQL

      sig { params(db: Sequel::Database, config: Config).void }
      def initialize(db, config:)
        @db = db
        @config = config
      end

      sig { params(line: SettlementCsv::Line).returns(T.any(Target, Unmatched)) }
      def match(line)
        case line.type
        when 'capture' then capture(line)
        when 'refund' then refund(line)
        else dispute(line)
        end
      end

      private

      sig { params(line: SettlementCsv::Line).returns(T.any(Target, Unmatched)) }
      def capture(line)
        payment = PaymentLookup.by_acquirer_reference(@db, line.acquirer_reference)
        return unknown("no payment has acquirer reference #{line.acquirer_reference}") unless payment

        posting = first_posting(payment.id, Ledger::Flows::RECEIVABLE, 'D')
        return unknown("payment #{payment.id} has no capture in the ledger") unless posting

        gross = Money.of(Integer(posting.fetch(:amount)), posting.fetch(:currency))
        target(flow_id: payment.id, flow_type: Ledger::Flows::PAYMENT, merchant_id: payment.merchant_id,
               payment_intent: payment.id, clearing_account: Ledger::Flows::RECEIVABLE,
               expected_amount: gross.amount, expected_fee: @config.expected_acquirer_fee(gross).amount,
               currency: gross.currency, posting: posting)
      end

      sig { params(line: SettlementCsv::Line).returns(T.any(Target, Unmatched)) }
      def refund(line)
        refund = PaymentLookup.refund_by_acquirer_operation(@db, line.operation_id)
        return unknown("no refund has acquirer operation #{line.operation_id}") unless refund

        posting = first_posting(refund.id, Ledger::Flows::REFUND_CLEARING, 'C')
        return unknown("refund #{refund.id} has no posting in the ledger") unless posting

        target(flow_id: refund.id, flow_type: Ledger::Flows::REFUND, merchant_id: refund.merchant_id,
               payment_intent: refund.payment_intent, clearing_account: Ledger::Flows::REFUND_CLEARING,
               expected_amount: -Integer(posting.fetch(:amount)), expected_fee: 0,
               currency: posting.fetch(:currency), posting: posting)
      end

      # `dispute` lines match the dispute's opening, `dispute_reversal` lines its win.
      # The acquirer's operation id on both is its dispute id.
      sig { params(line: SettlementCsv::Line).returns(T.any(Target, Unmatched)) }
      def dispute(line)
        dispute = Disputes.by_acquirer_id(@db, line.operation_id)
        return not_yet(line, "dispute #{line.operation_id} is not recorded here yet") unless dispute

        reversal = line.type == 'dispute_reversal'
        txn_id = reversal ? dispute.won_transaction_id : dispute.opened_transaction_id
        return not_yet(line, "dispute #{dispute.id} is not won here yet") unless txn_id

        posting = T.must(@db[:ledger_transactions].where(id: txn_id).first)
        amount = dispute.amount.amount
        target(flow_id: dispute.id, flow_type: Ledger::Flows::DISPUTE, merchant_id: dispute.merchant_id,
               payment_intent: dispute.payment_intent, clearing_account: Ledger::Flows::DISPUTE_CLEARING,
               expected_amount: reversal ? amount : -amount, expected_fee: 0, currency: dispute.amount.currency,
               posting: posting)
      end

      # A dispute line ahead of the notification that tells us about it is pending,
      # as long as the payment it names is ours. Otherwise it is money for a payment
      # we have never seen.
      sig { params(line: SettlementCsv::Line, detail: String).returns(Unmatched) }
      def not_yet(line, detail)
        return unknown("no payment has acquirer reference #{line.acquirer_reference}") unless
          PaymentLookup.by_acquirer_reference(@db, line.acquirer_reference)

        Unmatched.new(pending: true, detail: detail)
      end

      sig { params(detail: String).returns(Unmatched) }
      def unknown(detail)
        Unmatched.new(pending: false, detail: detail)
      end

      sig do
        params(flow_id: String, flow_type: String, merchant_id: String, payment_intent: String,
               clearing_account: String, expected_amount: Integer, expected_fee: Integer, currency: String,
               posting: T::Hash[Symbol, T.untyped]).returns(Target)
      end
      def target(flow_id:, flow_type:, merchant_id:, payment_intent:, clearing_account:, expected_amount:,
                 expected_fee:, currency:, posting:)
        Target.new(flow_id: flow_id, flow_type: flow_type, merchant_id: merchant_id, payment_intent: payment_intent,
                   clearing_account: clearing_account, expected_amount: expected_amount, expected_fee: expected_fee,
                   currency: currency, happened_at: posting.fetch(:effective_at).utc,
                   recorded_at: posting.fetch(:created_at).utc)
      end

      sig { params(flow_id: String, account: String, side: String).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def first_posting(flow_id, account, side)
        @db.fetch(FIRST_POSTING, flow_id, account, side).first
      end
    end
  end
end
