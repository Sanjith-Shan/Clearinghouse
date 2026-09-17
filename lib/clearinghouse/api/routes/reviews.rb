# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # Risk reviews: payments RiskGate sent to review, whose money is held back from
      # payouts until someone approves or rejects them. Stripe's Reviews API has
      # approve; reject is Clearinghouse's, and refunds the payment.
      module Reviews
        extend T::Sig

        LIST_LIMIT_MAX = 100

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          app.get '/v1/reviews' do
            T.bind(self, App)
            p = api_params.permit!('limit', 'starting_after', 'open')
            respond(Routes::Reviews.list(p, ctx))
          end

          app.get '/v1/reviews/:id' do |id|
            T.bind(self, App)
            api_params.permit!
            hold = Balances::Holds.find(ctx.db, id: id, merchant_id: ctx.merchant!.id) ||
                   raise(Errors::NotFoundError.resource('review', id))
            respond(hold.to_api)
          end

          app.post '/v1/reviews/:id/approve' do |id|
            T.bind(self, App)
            api_params.permit!
            run_flow(Balances::ReviewFlows::APPROVE, Balances::ReviewFlows::Input.new(review_id: id))
          end

          app.post '/v1/reviews/:id/reject' do |id|
            T.bind(self, App)
            api_params.permit!
            run_flow(Balances::ReviewFlows::REJECT, Balances::ReviewFlows::Input.new(review_id: id))
          end
        end

        sig { params(params: Params, ctx: Context).returns(T::Hash[String, T.untyped]) }
        def self.list(params, ctx)
          starting_after = params.string('starting_after')
          holds, more = Balances::Holds.list(
            ctx.db, merchant_id: ctx.merchant!.id, limit: params.integer('limit', min: 1, max: LIST_LIMIT_MAX) || 10,
                    starting_after: starting_after, open: params.boolean('open')
          )
          { 'object' => 'list', 'url' => '/v1/reviews', 'has_more' => more, 'data' => holds.map(&:to_api) }
        rescue Balances::Holds::NotFoundError
          raise Errors::NotFoundError.resource('review', starting_after.to_s, param: 'starting_after')
        end
      end
    end
  end
end
