# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Risk
    # The seam between a review decision and the payouts side, which owns holds.
    # Payouts is building `Clearinghouse::Balances::Holds.open_hold!`; until it
    # lands, the process-wide `Risk.holds` is Unwired, which raises, and the specs
    # use a stand-in.
    module Holds
      extend T::Sig
      extend T::Helpers

      interface!

      class NotWired < Clearinghouse::Error; end

      REASON = 'risk_review'

      # Holds `amount` of this payment's funds back from the merchant's payouts until
      # the review is closed. Called inside the caller's database transaction.
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

      # Forwards to an object with the payouts area's
      # `open_hold!(db, merchant_id:, source_id:, amount:, reason:, clock:)`, which
      # is what `Clearinghouse::Balances::Holds` is being built to. Wiring it is one
      # line at boot: `Risk.holds = Risk::Holds::Delegate.new(Balances::Holds)`.
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
          @target.open_hold!(db, merchant_id: merchant_id, source_id: payment_intent_id, amount: amount,
                                 reason: reason, clock: clock)
        end
      end
    end
  end
end
