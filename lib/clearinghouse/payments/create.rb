# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # POST /v1/payment_intents. One write: the intent and its created event.
    module Create
      extend T::Sig

      # What the request asked for, parsed and validated by the route.
      class Input < T::Struct
        const :amount, Integer
        const :currency, String
        const :payment_method, T.nilable(String)
        const :capture_method, String
        const :customer_email, T.nilable(String)
        const :metadata, T::Hash[String, String]
        const :risk_fields, T::Hash[String, T.untyped]
      end

      sig { params(db: Sequel::Database, ctx: Api::Context, input: Input).returns(PaymentIntent) }
      def self.create!(db, ctx, input)
        Support.check_covers_fee!(ctx.merchant!, Money.of(input.amount, input.currency), 'amount')
        now = ctx.clock.now
        intent = PaymentIntent.new(
          id: Ids.generate('pi'), merchant_id: ctx.merchant!.id, amount: input.amount, currency: input.currency,
          status: StateMachine.initial(payment_method: input.payment_method), capture_method: input.capture_method,
          payment_method: input.payment_method, customer_email: input.customer_email, metadata: input.metadata,
          risk_fields: input.risk_fields, created_at: now, updated_at: now
        )
        PaymentIntents.insert!(db, intent)
        Support.emit!(db, ctx, 'payment_intent.created', intent.to_api)
        intent
      end
    end
  end
end
