# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # POST /v1/payment_intents/:id/capture, as steps (see Confirm for the shape).
    #
    #   check!    requires_capture, amount within the authorization, not expired
    #   request   the acquirer capture, under the intent's capture key
    #   record!   requires_capture -> succeeded, release the rest, ledger, event
    module Capture
      extend T::Sig

      # What the request asked for, parsed and validated by the route.
      class Input < T::Struct
        const :intent_id, String
        const :amount_to_capture, T.nilable(Integer)
      end

      # The amount to capture. Everything that can refuse the capture is checked
      # here, before the acquirer hears about it.
      sig { params(db: Sequel::Database, ctx: Api::Context, input: Input).returns([PaymentIntent, Money]) }
      def self.check!(db, ctx, input)
        intent = PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: input.intent_id)
        Errors.transition!(intent, StateMachine::Event::Capture)
        expires_at = T.must(intent.authorization_expires_at)
        if ctx.clock.now >= expires_at
          raise Api::Errors::InvalidRequestError.new(
            "This PaymentIntent's authorization expired at #{expires_at.iso8601} and can no longer be captured.",
            code: 'payment_intent_authorization_expired'
          )
        end

        amount = input.amount_to_capture || intent.amount_capturable
        if amount > intent.amount_capturable
          raise Api::Errors::InvalidRequestError.invalid_parameter(
            'amount_to_capture', "#{amount} is greater than the amount capturable (#{intent.amount_capturable})."
          )
        end
        money = Money.of(amount, intent.currency)
        Support.check_covers_fee!(ctx.merchant!, money, 'amount_to_capture')
        [intent, money]
      end

      sig { params(intent: PaymentIntent).returns(String) }
      def self.acquirer_key(intent)
        "#{intent.id}:capture:#{intent.attempt}"
      end

      sig { params(ctx: Api::Context, intent: PaymentIntent, amount: Money).returns(Acquirer::Outcome) }
      def self.request(ctx, intent, amount)
        ctx.acquirer!.capture(acquirer_reference: T.must(intent.acquirer_reference), amount: amount,
                              idempotency_key: acquirer_key(intent))
      end

      sig { params(ctx: Api::Context, intent: PaymentIntent).returns(Acquirer::LookupOutcome) }
      def self.look_up(ctx, intent)
        ctx.acquirer!.lookup(acquirer_key(intent))
      end

      # A partial capture releases the rest: amount_capturable goes to zero whatever
      # was captured, because the acquirer allows one capture per authorization.
      # A refusal (the acquirer says the authorization cannot be captured) changes
      # nothing and is reported as an error.
      sig do
        params(db: Sequel::Database, ctx: Api::Context, intent_id: String, amount: Money,
               outcome: T.any(Acquirer::Approved, Acquirer::Declined)).returns(PaymentIntent)
      end
      def self.record!(db, ctx, intent_id, amount, outcome)
        intent = PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: intent_id)
        if outcome.is_a?(Acquirer::Declined)
          raise Api::Errors::InvalidRequestError.new("The capture was refused by the card network (#{outcome.code}).",
                                                     code: 'capture_failed')
        end

        to = Errors.transition!(intent, StateMachine::Event::Capture)
        done = Support.save!(db, ctx, intent, intent.copy(status: to, amount_received: amount.amount,
                                                          amount_capturable: 0))
        Support.post_capture!(db, ctx, done, amount)
        Support.emit!(db, ctx, 'payment_intent.succeeded', done.to_api)
        done
      end
    end
  end
end
