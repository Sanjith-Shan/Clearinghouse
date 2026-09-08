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
            respond(Routes::Payouts.create(p, ctx).to_api)
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
            respond(Routes::Payouts.cancel(ctx, id).to_api)
          end
        end

        sig { params(params: Params, ctx: Context).returns(Clearinghouse::Payouts::Payout) }
        def self.create(params, ctx)
          currency = params.string('currency') || 'usd'
          unless Currency.known?(currency)
            raise Errors::InvalidRequestError.invalid_parameter('currency', 'is not a supported currency.')
          end

          Clearinghouse::Payouts.create!(
            ctx.db, merchant_id: ctx.merchant!.id, currency: currency, bank: bank(ctx), clock: ctx.clock,
                    amount: params.integer('amount', min: 1), metadata: params.metadata,
                    description: params.string('description', max_length: 1000)
          )
        rescue Clearinghouse::Payouts::BalanceInsufficientError => e
          raise Errors::InvalidRequestError.new(
            "Your available balance (#{e.available}) is too low for this payout. Payouts are refused while " \
            'the available balance is zero or negative.', code: 'balance_insufficient', param: 'amount'
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

        sig { params(ctx: Context, id: String).returns(Clearinghouse::Payouts::Payout) }
        def self.cancel(ctx, id)
          Clearinghouse::Payouts.cancel!(ctx.db, id, merchant_id: ctx.merchant!.id, clock: ctx.clock)
        rescue Clearinghouse::Payouts::NotFoundError
          raise Errors::NotFoundError.resource('payout', id)
        rescue Clearinghouse::Payouts::NotCancelableError => e
          raise Errors::InvalidRequestError.new("This payout cannot be canceled: #{e.message}. Only a pending " \
                                                'payout that has not been sent to the bank can be canceled.',
                                                code: 'payout_not_cancelable')
        end

        # Payouts go through the same acquirer connection as payments (the simulator
        # plays the bank too).
        sig { params(ctx: Context).returns(Acquirer::Client) }
        def self.bank(ctx)
          acquirer = ctx.deps.acquirer
          raise Clearinghouse::Error, 'no acquirer client configured' unless acquirer.is_a?(Acquirer::Client)

          acquirer
        end
      end
    end
  end
end
