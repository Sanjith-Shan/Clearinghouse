# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # POST /v1/payment_intents/:id/cancel, as steps (see Confirm for the shape).
    #
    #   check!    a cancelable status
    #   void      only when there is an authorization to release
    #   record!   -> canceled, event
    #
    # Nothing is posted to the ledger: an uncaptured authorization never moved
    # money.
    module Cancel
      extend T::Sig

      REASONS = %w[duplicate fraudulent requested_by_customer abandoned].freeze

      # What the request asked for, parsed and validated by the route.
      class Input < T::Struct
        const :intent_id, String
        const :cancellation_reason, T.nilable(String)
      end

      sig { params(db: Sequel::Database, ctx: Api::Context, input: Input).returns(PaymentIntent) }
      def self.check!(db, ctx, input)
        intent = PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: input.intent_id)
        Errors.transition!(intent, StateMachine::Event::Cancel)
        intent
      end

      # Whether canceling this intent has to release an authorization first.
      sig { params(intent: PaymentIntent).returns(T::Boolean) }
      def self.needs_void?(intent)
        intent.status == StateMachine::Status::RequiresCapture
      end

      sig { params(intent: PaymentIntent).returns(String) }
      def self.acquirer_key(intent)
        "#{intent.id}:void:#{intent.attempt}"
      end

      sig { params(ctx: Api::Context, intent: PaymentIntent).returns(Acquirer::Outcome) }
      def self.void(ctx, intent)
        ctx.acquirer!.void(acquirer_reference: T.must(intent.acquirer_reference), idempotency_key: acquirer_key(intent))
      end

      sig { params(ctx: Api::Context, intent: PaymentIntent).returns(Acquirer::LookupOutcome) }
      def self.look_up(ctx, intent)
        ctx.acquirer!.lookup(acquirer_key(intent))
      end

      # A refused void still cancels: the acquirer refuses a void only for an
      # authorization that can no longer be captured (voided or expired on its
      # side), and nothing on ours will capture a canceled intent either.
      sig do
        params(db: Sequel::Database, ctx: Api::Context, input: Input,
               event: StateMachine::Event, reason: T.nilable(String)).returns(PaymentIntent)
      end
      def self.record!(db, ctx, input, event: StateMachine::Event::Cancel, reason: input.cancellation_reason)
        intent = PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: input.intent_id)
        to = Errors.transition!(intent, event)
        done = Support.save!(db, ctx, intent,
                             intent.copy(status: to, amount_capturable: 0, cancellation_reason: reason))
        Support.emit!(db, ctx, 'payment_intent.canceled', done.to_api)
        done
      end
    end
  end
end
