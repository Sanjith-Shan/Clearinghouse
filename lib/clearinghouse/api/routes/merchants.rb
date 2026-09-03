# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # Merchant bootstrap and the authenticated merchant's own account.
      #
      # POST /v1/merchants has no Stripe equivalent: Stripe onboards merchants
      # through its dashboard. Clearinghouse is a simulation, so demos and
      # experiments create merchants over the API, guarded by an admin token from
      # CLEARINGHOUSE_ADMIN_TOKEN. The response is the only time the secret key is
      # ever shown.
      module Merchants
        extend T::Sig

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          app.post '/v1/merchants' do
            T.bind(self, App)
            Auth.admin!(deps.admin_token, request.get_header('HTTP_AUTHORIZATION'))
            p = api_params.permit!('name', 'api_version', 'fee_percent',
                                   { 'payout_schedule' => %w[interval delay_days] }, free_form: ['fee_fixed'])
            merchant, secret_key = Routes::Merchants.create(p, ctx)
            ctx.merchant = merchant
            respond(merchant.to_api.merge('secret_key' => secret_key), status_code: 201)
          end

          app.get '/v1/account' do
            T.bind(self, App)
            api_params.permit!
            respond(ctx.merchant!.to_api)
          end
        end

        sig { params(params: Params, ctx: Context).returns([Merchant, String]) }
        def self.create(params, ctx)
          versioning = ctx.deps.versioning
          schedule = params.nested('payout_schedule')
          Clearinghouse::Merchants.create(
            ctx.db, clock: ctx.clock,
                    name: T.must(params.string('name', required: true, max_length: 200)),
                    api_version: params.enum('api_version', versioning.versions) || versioning.latest,
                    fee_schedule: fee_schedule(params),
                    payout_interval: schedule.enum('interval', Clearinghouse::Merchants::PAYOUT_INTERVALS) || 'daily',
                    payout_delay_days: schedule.integer('delay_days', min: 0, max: 30) ||
                                       Clearinghouse::Merchants::DEFAULT_PAYOUT_DELAY_DAYS
          )
        end

        sig { params(params: Params).returns(FeeSchedule) }
        def self.fee_schedule(params)
          default = FeeSchedule.us_card_default
          percent = params.string('fee_percent')
          rate = percent ? parse_percent(percent) : default.rate_scaled
          fixed = params['fee_fixed'].nil? ? default.fixed_minor : fixed_fees(params['fee_fixed'])
          FeeSchedule.new(rate_scaled: rate, fixed_minor: fixed)
        end

        sig { params(text: String).returns(Integer) }
        def self.parse_percent(text)
          Clearinghouse::Merchants.parse_percent(text)
        rescue ArgumentError
          raise Errors::InvalidRequestError.invalid_parameter('fee_percent', 'must be a percentage like "2.9".')
        end

        sig { params(value: T.untyped).returns(T::Hash[String, Integer]) }
        def self.fixed_fees(value)
          unless value.is_a?(Hash)
            raise Errors::InvalidRequestError.invalid_parameter('fee_fixed',
                                                                'must be an object.')
          end

          value.to_h do |currency, _amount|
            unless Currency.known?(currency.to_s)
              raise Errors::InvalidRequestError.invalid_parameter("fee_fixed[#{currency}]",
                                                                  'is not a supported currency.')
            end

            [currency.to_s.downcase,
             T.must(Params.new(value, prefix: 'fee_fixed').integer(currency, required: true, min: 0))]
          end
        end
      end
    end
  end
end
