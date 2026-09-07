# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # POST /v1/payment_intents/:id/confirm, as steps. Each `!` step is local
    # database work meant to run in one transaction, and the acquirer call sits
    # between them, never inside one. The idempotency layer runs these steps as
    # its atomic phases (docs/design/idempotency.md).
    #
    #   lock!                  requires_* -> processing, attempt + 1
    #   authorize / look_up    the acquirer, under the attempt's own key
    #   record_authorization!  store the acquirer's answer; a decline ends here
    #   apply_approval!        processing -> requires_capture or succeeded, ledger, event
    module Confirm
      extend T::Sig

      # What the request asked for, parsed and validated by the route.
      class Input < T::Struct
        const :intent_id, String
        const :payment_method, T.nilable(String)
      end

      E = StateMachine::Event
      S = StateMachine::Status

      # Starts a new attempt. The attempt number is what makes the acquirer key
      # (PaymentIntent#authorization_key), so it is only ever bumped here, once per
      # confirmation, never on a retry of the same one.
      sig { params(db: Sequel::Database, ctx: Api::Context, input: Input).returns(PaymentIntent) }
      def self.lock!(db, ctx, input)
        intent = PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: input.intent_id)
        to = Errors.transition!(intent, E::Confirm)
        payment_method = input.payment_method || intent.payment_method
        unless payment_method
          raise Api::Errors::InvalidRequestError.new(
            'You cannot confirm this PaymentIntent because it has no payment method. Pass payment_method.',
            code: 'parameter_missing', param: 'payment_method'
          )
        end

        Support.save!(db, ctx, intent, intent.copy(status: to, payment_method: payment_method,
                                                   attempt: intent.attempt + 1, last_payment_error: nil))
      end

      # The authorization itself. Automatic capture asks the acquirer to capture in
      # the same call, so one request moves the money.
      sig { params(ctx: Api::Context, intent: PaymentIntent).returns(Acquirer::Outcome) }
      def self.authorize(ctx, intent)
        ctx.acquirer!.authorize(payment_method: T.must(intent.payment_method), amount: intent.money,
                                capture: intent.capture_method == 'automatic', reference: intent.id,
                                idempotency_key: intent.authorization_key)
      end

      # What the acquirer did under this attempt's key, without asking it to do
      # anything. Used when resuming an attempt that may already have been sent.
      sig { params(ctx: Api::Context, intent: PaymentIntent).returns(Acquirer::LookupOutcome) }
      def self.look_up(ctx, intent)
        ctx.acquirer!.lookup(intent.authorization_key)
      end

      # Records a definite answer. An approval is only stored here (the reference
      # and the charge id); a decline is the end of the attempt: the intent goes
      # back to requires_payment_method with the reason, and the payment method is
      # cleared, as Stripe does, so the next confirm has to supply a new one.
      sig do
        params(db: Sequel::Database, ctx: Api::Context, intent_id: String,
               outcome: T.any(Acquirer::Approved, Acquirer::Declined)).returns(PaymentIntent)
      end
      def self.record_authorization!(db, ctx, intent_id, outcome)
        intent = PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: intent_id)
        case outcome
        when Acquirer::Approved
          record_approval(db, ctx, intent, outcome)
        when Acquirer::Declined
          to = Errors.transition!(intent, E::AuthorizationDeclined)
          declined = Support.save!(db, ctx, intent, intent.copy(
                                                      status: to, payment_method: nil,
                                                      last_payment_error: Errors.last_payment_error(outcome.code)
                                                    ))
          Support.emit!(db, ctx, 'payment_intent.payment_failed', declined.to_api)
          declined
        end
      end

      sig do
        params(db: Sequel::Database, ctx: Api::Context, intent: PaymentIntent,
               outcome: Acquirer::Approved).returns(PaymentIntent)
      end
      def self.record_approval(db, ctx, intent, outcome)
        # Only an intent still waiting on its authorization takes an approval.
        raise Errors.unexpected_state(unexpected(intent)) unless intent.status == S::Processing

        now = ctx.clock.now
        Support.save!(db, ctx, intent, intent.copy(
                                         acquirer_reference: outcome.operation.acquirer_reference,
                                         latest_charge: Ids.generate('ch'), authorized_at: now,
                                         authorization_expires_at: now + (ctx.deps.authorization_ttl_days *
                                                                           Clock::SECONDS_PER_DAY)
                                       ))
      end
      private_class_method :record_approval

      # Applies a recorded approval: manual capture waits for the capture call,
      # automatic capture has already moved the money, so the ledger is posted now.
      sig { params(db: Sequel::Database, ctx: Api::Context, intent_id: String).returns(PaymentIntent) }
      def self.apply_approval!(db, ctx, intent_id)
        intent = PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: intent_id)
        to = Errors.transition!(intent, E::AuthorizationApproved)
        if to == S::Succeeded
          done = Support.save!(db, ctx, intent, intent.copy(status: to, amount_received: intent.amount))
          Support.post_capture!(db, ctx, done, done.money)
          Support.emit!(db, ctx, 'payment_intent.succeeded', done.to_api)
        else
          done = Support.save!(db, ctx, intent, intent.copy(status: to, amount_capturable: intent.amount))
          Support.emit!(db, ctx, 'payment_intent.amount_capturable_updated', done.to_api)
        end
        done
      end

      sig { params(intent: PaymentIntent).returns(StateMachine::UnexpectedStateError) }
      def self.unexpected(intent)
        StateMachine::UnexpectedStateError.new(intent.status, E::AuthorizationApproved,
                                               StateMachine.message(intent.status, E::AuthorizationApproved))
      end
      private_class_method :unexpected
    end
  end
end
