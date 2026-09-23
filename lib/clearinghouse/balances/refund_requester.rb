# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Balances
    # How rejecting a review refunds the payment. Refunds belong to the payments
    # area; PaymentsRefundRequester is the implementation a request uses.
    #
    # The contract, for whoever implements it:
    #
    # - `request_refund!` runs inside the reject's database transaction and must
    #   only *start* the refund there (create the refund and reserve its amount),
    #   returning the refund id. The acquirer call happens in the refund's own later
    #   phases, as for any refund.
    # - When the refund posts its ledger entries (merchant available -> refund
    #   clearing), it first calls `Holds.release_after_refund!(db, flow_id:, clock:,
    #   refund_entries:)` in that same transaction, with those entries. That moves
    #   the payment's held money back to available in the transaction that takes it
    #   out, so the held money is never payable on its own. Calling it before the
    #   refund's own posting keeps the transaction's locks in the one order the rest
    #   of the system uses (docs/design/payouts.md, Races).
    module RefundRequester
      extend T::Sig
      extend T::Helpers

      interface!

      sig do
        abstract.params(db: Sequel::Database, payment_intent_id: String, reason: String, clock: Clock).returns(String)
      end
      def request_refund!(db, payment_intent_id:, reason:, clock:); end
    end

    # Raised by the default requester: a reject needs a request context (the
    # merchant, the acquirer) to refund through, so it has to pass one in.
    class RefundsNotWiredError < Clearinghouse::Error; end

    # The default for callers without a request context. Refuses loudly rather
    # than closing a review as rejected without refunding anything.
    class UnwiredRefundRequester
      extend T::Sig
      include RefundRequester

      sig { override.params(db: Sequel::Database, payment_intent_id: String, reason: String, clock: Clock).returns(String) }
      def request_refund!(db, payment_intent_id:, reason:, clock:) # rubocop:disable Lint/UnusedMethodArgument
        raise RefundsNotWiredError,
              "cannot refund #{payment_intent_id}: pass a RefundRequester such as PaymentsRefundRequester"
      end
    end

    DEFAULT_REFUNDS = T.let(UnwiredRefundRequester.new, RefundRequester)

    # Rejects through the payments area's refunds. `request_refund!` runs the
    # refund's first step (Refunds.reserve!: create it pending, reserve the amount
    # on the intent) inside the reject's transaction. The rest of the refund, the
    # acquirer call and its record, is the refund flow's own phases, which the
    # reject flow (ReviewFlows::Reject) runs after that transaction commits. So a
    # rejected review's refund is idempotent and crash-recoverable exactly like
    # POST /v1/refunds: if the reject stops half way, its key sits at a refund
    # recovery point and the completer finishes it.
    class PaymentsRefundRequester
      extend T::Sig
      include RefundRequester

      sig { params(ctx: Api::Context).void }
      def initialize(ctx)
        @ctx = ctx
      end

      sig do
        override.params(db: Sequel::Database, payment_intent_id: String, reason: String, clock: Clock).returns(String)
      end
      def request_refund!(db, payment_intent_id:, reason:, clock:) # rubocop:disable Lint/UnusedMethodArgument
        input = Payments::Refunds::Input.new(payment_intent_id: payment_intent_id, amount: nil, reason: reason,
                                             metadata: {})
        Payments::Refunds.reserve!(db, @ctx, input).id
      end
    end
  end
end
