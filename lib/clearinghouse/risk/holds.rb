# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Risk
    # The seam between a review decision and the payouts side, which owns holds
    # (`Clearinghouse::Balances::Holds`). The API wires it through
    # `Api::Dependencies#risk_holds`, a Delegate to Balances::Holds. The
    # process-wide `Risk.holds`, the default for callers that pass nothing, stays
    # Unwired, which raises, so a review can never pass silently without a hold.
    module Holds
      extend T::Sig
      extend T::Helpers

      interface!

      class NotWired < Clearinghouse::Error; end

      REASON = 'risk_review'

      # Holds this payment's funds back from the merchant's payouts until the
      # review is closed. `amount` is what was captured, the amount under review;
      # the money actually kept out of available is the merchant's net of it,
      # which the availability sweep moves to held. Called inside the caller's
      # database transaction.
      sig do
        abstract.params(db: T.untyped, merchant_id: String, payment_intent_id: String, amount: Money,
                        reason: String, clock: Clock).void
      end
      def open_hold!(db, merchant_id:, payment_intent_id:, amount:, reason:, clock:); end

      # Where review holds go until the payouts area is wired in: raises, so a
      # review can never pass silently without its hold.
      class Unwired
        extend T::Sig
        include Holds

        # The interface fixes the keyword names, so the unused ones stay.

        sig do
          override.params(db: T.untyped, merchant_id: String, payment_intent_id: String, amount: Money,
                          reason: String, clock: Clock).void
        end
        def open_hold!(db, merchant_id:, payment_intent_id:, amount:, reason:, clock:) # rubocop:disable Lint/UnusedMethodArgument
          raise NotWired, "no holds backend for #{payment_intent_id}; set Clearinghouse::Risk.holds " \
                          '(Balances::Holds from the payouts area)'
        end
      end

      # Forwards to an object with the payouts area's signature,
      # `open_hold!(db, flow_id:, merchant_id:, amount:, reason:, clock:)`
      # (`Clearinghouse::Balances::Holds`), where the payment is named by its
      # ledger flow id, which for a payment is its `pi_` id.
      class Delegate
        extend T::Sig
        include Holds

        sig { params(target: T.untyped).void }
        def initialize(target)
          @target = target
        end

        sig do
          override.params(db: T.untyped, merchant_id: String, payment_intent_id: String, amount: Money,
                          reason: String, clock: Clock).void
        end
        def open_hold!(db, merchant_id:, payment_intent_id:, amount:, reason:, clock:)
          @target.open_hold!(db, flow_id: payment_intent_id, merchant_id: merchant_id, amount: amount,
                                 reason: reason, clock: clock)
        end
      end
    end
  end
end
