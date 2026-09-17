# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # Payouts, in the shape of Stripe's Payouts API. `amount` is optional here:
      # without it the payout is the whole available balance in that currency.
      module Payouts
        extend T::Sig

        LIST_LIMIT_MAX = 100

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          app.post '/v1/payouts' do
            T.bind(self, App)
            p = api_params.permit!('amount', 'currency', 'description')
            input = Routes::Payouts.input(p)
            # Without a bank there is nothing to send the payout to: fail before
            # anything is reserved.
            ctx.acquirer!
            run_flow(Clearinghouse::Payouts::Flows::CREATE, input)
          end

          app.get '/v1/payouts' do
            T.bind(self, App)
            p = api_params.permit!('limit', 'starting_after', 'status')
            respond(Routes::Payouts.list(p, ctx))
          end

          app.get '/v1/payouts/:id' do |id|
            T.bind(self, App)
            api_params.permit!
            respond(Routes::Payouts.find!(ctx, id).to_api)
          end

          app.post '/v1/payouts/:id/cancel' do |id|
            T.bind(self, App)
            api_params.permit!
            run_flow(Clearinghouse::Payouts::Flows::CANCEL,
                     Clearinghouse::Payouts::Flows::CancelInput.new(payout_id: id))
          end
        end

        sig { params(params: Params).returns(Clearinghouse::Payouts::Flows::CreateInput) }
        def self.input(params)
          currency = params.string('currency') || 'usd'
          unless Currency.known?(currency)
            raise Errors::InvalidRequestError.invalid_parameter('currency', 'is not a supported currency.')
          end

          Clearinghouse::Payouts::Flows::CreateInput.new(
            currency: Currency.normalize(currency), amount: params.integer('amount', min: 1),
            description: params.string('description', max_length: 1000), metadata: params.metadata
          )
        end

        sig { params(params: Params, ctx: Context).returns(T::Hash[String, T.untyped]) }
        def self.list(params, ctx)
          limit = params.integer('limit', min: 1, max: LIST_LIMIT_MAX) || 10
          starting_after = params.string('starting_after')
          payouts, more = Clearinghouse::Payouts.list(
            ctx.db, merchant_id: ctx.merchant!.id, limit: limit, starting_after: starting_after,
                    status: params.enum('status', Clearinghouse::Payouts::STATUSES)
          )
          { 'object' => 'list', 'url' => '/v1/payouts', 'has_more' => more, 'data' => payouts.map(&:to_api) }
        rescue Clearinghouse::Payouts::NotFoundError
          raise Errors::NotFoundError.resource('payout', starting_after.to_s, param: 'starting_after')
        end

        sig { params(ctx: Context, id: String).returns(Clearinghouse::Payouts::Payout) }
        def self.find!(ctx, id)
          Clearinghouse::Payouts.find(ctx.db, id, merchant_id: ctx.merchant!.id) ||
            raise(Errors::NotFoundError.resource('payout', id))
        end
      end
    end
  end
end
