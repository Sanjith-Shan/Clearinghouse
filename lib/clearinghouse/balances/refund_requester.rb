# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Balances
    # How rejecting a review refunds the payment. Refunds belong to the payments
    # area and are not on main yet, so Holds calls through this seam.
    #
    # The contract, for whoever implements it:
    #
    # - `request_refund!` runs inside the reject's database transaction and must
    #   only *start* the refund there (create the refund and reserve its amount),
    #   returning the refund id. The acquirer call happens in the refund's own later
    #   phases, as for any refund.
    # - When the refund posts its ledger entries (merchant available -> refund
    #   clearing), it calls `Holds.release_after_refund!(db, flow_id:, clock:)` in
    #   that same transaction. That moves the payment's held money back to available
    #   at the exact moment the refund takes it out, so the held money is never
    #   payable on its own.
    module RefundRequester
      extend T::Sig
      extend T::Helpers

      interface!

      sig do
        abstract.params(db: Sequel::Database, payment_intent_id: String, reason: String, clock: Clock).returns(String)
      end
      def request_refund!(db, payment_intent_id:, reason:, clock:); end
    end

    # Raised by the default requester: rejecting a review cannot work until the
    # payments area's refunds are wired in.
    class RefundsNotWiredError < Clearinghouse::Error; end

    # The default until refunds land. Refuses loudly rather than closing a review
    # as rejected without refunding anything.
    class UnwiredRefundRequester
      extend T::Sig
      include RefundRequester

      sig { override.params(db: Sequel::Database, payment_intent_id: String, reason: String, clock: Clock).returns(String) }
      def request_refund!(db, payment_intent_id:, reason:, clock:) # rubocop:disable Lint/UnusedMethodArgument
        raise RefundsNotWiredError, "cannot refund #{payment_intent_id}: refunds are not wired into Balances yet"
      end
    end

    DEFAULT_REFUNDS = T.let(UnwiredRefundRequester.new, RefundRequester)
  end
end
