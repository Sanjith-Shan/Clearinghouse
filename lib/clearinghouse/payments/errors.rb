# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # The typed errors payments code raises, built in one place so the codes and
    # messages are consistent. Everything here is an Api::Errors class: the caller
    # did something the object's state or the card does not allow.
    module Errors
      extend T::Sig

      # Stripe's messages for the declines the test cards produce. The code is
      # `card_declined` with the issuer's reason in decline_code, except an expired
      # card, which has its own code as in Stripe's API.
      DECLINES = T.let({
        'generic_decline' => ['card_declined', 'Your card was declined.'],
        'insufficient_funds' => ['card_declined', 'Your card has insufficient funds.'],
        'expired_card' => ['expired_card', 'Your card has expired.']
      }.freeze, T::Hash[String, [String, String]])

      # The intent's last_payment_error for a decline, in the fixture's key order.
      sig { params(decline_code: String).returns(T::Hash[String, T.untyped]) }
      def self.last_payment_error(decline_code)
        code, message = DECLINES.fetch(decline_code) { ['card_declined', 'Your card was declined.'] }
        { 'code' => code, 'decline_code' => decline_code, 'message' => message }
      end

      sig { params(last_payment_error: T::Hash[String, T.untyped]).returns(Api::Errors::CardError) }
      def self.card_error(last_payment_error)
        Api::Errors::CardError.new(last_payment_error.fetch('message'),
                                   code: last_payment_error.fetch('code'),
                                   decline_code: last_payment_error['decline_code'])
      end

      sig { params(error: StateMachine::UnexpectedStateError).returns(Api::Errors::InvalidRequestError) }
      def self.unexpected_state(error)
        Api::Errors::InvalidRequestError.new(error.message, code: 'payment_intent_unexpected_state')
      end

      # The status after `event`, or the API's unexpected-state error. Services call
      # this instead of StateMachine.transition so every refusal looks the same.
      sig { params(intent: PaymentIntent, event: StateMachine::Event).returns(StateMachine::Status) }
      def self.transition!(intent, event)
        StateMachine.transition(intent.status, event, capture_method: intent.capture_method)
      rescue StateMachine::UnexpectedStateError => e
        raise unexpected_state(e)
      end
    end
  end
end
