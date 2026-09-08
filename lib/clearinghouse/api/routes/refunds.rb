# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # Refunds and the merchant's balance.
      module Refunds
        extend T::Sig

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          app.post '/v1/refunds' do
            T.bind(self, App)
            input = Routes::Refunds.input(api_params)
            refund = Payments::Operations.refund(ctx, input)
            respond(Payments::Refunds.to_api(ctx.db, ctx, refund))
          end

          app.get '/v1/refunds/:id' do |id|
            T.bind(self, App)
            api_params.permit!
            respond(Payments::Refunds.to_api(ctx.db, ctx, Payments::Refunds.find!(ctx.db, ctx, id)))
          end

          app.get '/v1/balance' do
            T.bind(self, App)
            api_params.permit!
            respond(Payments::Balance.to_api(ctx.db, ctx.merchant!))
          end
        end

        sig { params(params: Params).returns(Payments::Refunds::Input) }
        def self.input(params)
          p = params.permit!('payment_intent', 'amount', 'reason')
          Payments::Refunds::Input.new(payment_intent_id: T.must(p.string('payment_intent', required: true)),
                                       amount: p.integer('amount', min: 1),
                                       reason: p.enum('reason', Payments::Refund::REASONS), metadata: p.metadata)
        end
      end
    end
  end
end
