# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # A system under test: one method per operation, each returning the Outcome
      # the system produced, plus `snapshot` for the checks and `reset!` between
      # sequences. The reference model implements it too, so the model can be run
      # against itself as a sanity check of the harness.
      #
      # Objects are named by the sequence (m1, pi_3, re_1, po_2). An
      # implementation maps those names to its own ids and reports balances and
      # flows under the sequence's names, so results compare directly.
      module Sut
        extend T::Sig
        extend T::Helpers

        abstract!

        OPERATIONS = %i[
          create_merchant create_intent confirm capture cancel refund payout
          advance_clock resolve_dispute settle availability_sweep
        ].freeze

        sig { abstract.void }
        def reset!; end

        sig { abstract.returns(Snapshot) }
        def snapshot; end

        sig do
          abstract.params(merchant: String, fee_rate_scaled: Integer, fee_fixed: T::Hash[String, Integer])
                  .returns(Outcome)
        end
        def create_merchant(merchant:, fee_rate_scaled:, fee_fixed:); end

        sig do
          abstract.params(intent: String, merchant: String, amount: Integer, currency: String,
                          capture_method: String, payment_method: T.nilable(String)).returns(Outcome)
        end
        def create_intent(intent:, merchant:, amount:, currency:, capture_method:, payment_method: nil); end

        sig { abstract.params(intent: String, payment_method: String).returns(Outcome) }
        def confirm(intent:, payment_method:); end

        # amount nil captures everything authorized.
        sig { abstract.params(intent: String, amount: T.nilable(Integer)).returns(Outcome) }
        def capture(intent:, amount: nil); end

        sig { abstract.params(intent: String).returns(Outcome) }
        def cancel(intent:); end

        # amount nil refunds what is left.
        sig { abstract.params(refund: String, intent: String, amount: T.nilable(Integer)).returns(Outcome) }
        def refund(refund:, intent:, amount: nil); end

        # amount nil pays out the whole available balance.
        sig do
          abstract.params(payout: String, merchant: String, currency: String, amount: T.nilable(Integer))
                  .returns(Outcome)
        end
        def payout(payout:, merchant:, currency:, amount: nil); end

        # Moves simulated time forward, then lets the notification worker deliver
        # everything that fell due: disputes opening, payouts paid or failed.
        sig { abstract.params(hours: Integer).returns(Outcome) }
        def advance_clock(hours:); end

        # The card network's decision on the dispute of this payment ("won" or "lost").
        sig { abstract.params(intent: String, outcome: String).returns(Outcome) }
        def resolve_dispute(intent:, outcome:); end

        # Fetch and reconcile today's settlement file.
        sig { abstract.returns(Outcome) }
        def settle; end

        # Move every payment whose available_on has passed from pending to available.
        sig { abstract.returns(Outcome) }
        def availability_sweep; end

        # Operations this system cannot run yet; the generator leaves them out.
        sig { returns(T::Array[Symbol]) }
        def unsupported_operations
          []
        end

        # Test cards whose behaviour this system cannot reproduce yet.
        sig { returns(T::Array[String]) }
        def unsupported_payment_methods
          []
        end

        sig { params(command: Command).returns(Outcome) }
        def apply(command)
          Kernel.raise ArgumentError, "unknown operation #{command.op}" unless OPERATIONS.include?(command.op)

          T.unsafe(self).public_send(command.op, **command.args)
        end
      end
    end
  end
end
