# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # Runs each operation's steps in order, one database transaction per local
    # step, with the acquirer call between them. This is the synchronous path:
    # nothing here survives a crash between steps, which is what the idempotency
    # layer adds by recording a recovery point with each step.
    module Operations
      extend T::Sig

      sig { params(ctx: Api::Context, input: Create::Input).returns(PaymentIntent) }
      def self.create(ctx, input)
        ctx.db.transaction { Create.create!(ctx.db, ctx, input) }
      end

      sig { params(ctx: Api::Context, input: Confirm::Input).returns(PaymentIntent) }
      def self.confirm(ctx, input)
        intent = ctx.db.transaction { Confirm.lock!(ctx.db, ctx, input) }
        outcome = definite!(Confirm.authorize(ctx, intent))
        recorded = ctx.db.transaction { Confirm.record_authorization!(ctx.db, ctx, intent.id, outcome) }
        raise Errors.card_error(T.must(recorded.last_payment_error)) if outcome.is_a?(Acquirer::Declined)

        ctx.db.transaction { Confirm.apply_approval!(ctx.db, ctx, intent.id) }
      end

      sig { params(ctx: Api::Context, input: Capture::Input).returns(PaymentIntent) }
      def self.capture(ctx, input)
        intent, amount = ctx.db.transaction { Capture.check!(ctx.db, ctx, input) }
        outcome = definite!(Capture.request(ctx, intent, amount))
        ctx.db.transaction { Capture.record!(ctx.db, ctx, intent.id, amount, outcome) }
      end

      sig { params(ctx: Api::Context, input: Cancel::Input).returns(PaymentIntent) }
      def self.cancel(ctx, input)
        intent = ctx.db.transaction { Cancel.check!(ctx.db, ctx, input) }
        definite!(Cancel.void(ctx, intent)) if Cancel.needs_void?(intent)
        ctx.db.transaction { Cancel.record!(ctx.db, ctx, input) }
      end

      # The outcome if the acquirer gave a definite answer; otherwise a retryable
      # 503 and the intent stays where it is.
      sig do
        params(outcome: Acquirer::Outcome).returns(T.any(Acquirer::Approved, Acquirer::Declined))
      end
      def self.definite!(outcome)
        case outcome
        when Acquirer::Unknown, Acquirer::Unavailable then Support.acquirer_unavailable!(outcome)
        else outcome
        end
      end
    end
  end
end
