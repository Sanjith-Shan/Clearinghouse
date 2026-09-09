# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # PaymentIntents. Parameters are parsed and validated here, into each
      # operation's typed Input, before anything is written; the operations in
      # Payments do the rest.
      module PaymentIntents
        extend T::Sig

        LIST_LIMIT_MAX = 100
        LIST_LIMIT_DEFAULT = 10

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          register_reads(app)
          register_writes(app)
        end

        sig { params(app: T.class_of(App)).void }
        def self.register_reads(app)
          app.get '/v1/payment_intents' do
            T.bind(self, App)
            respond(Routes::PaymentIntents.list(ctx, api_params.permit!('limit', 'starting_after')))
          end

          app.get '/v1/payment_intents/:id' do |id|
            T.bind(self, App)
            api_params.permit!
            respond(Payments::PaymentIntents.find!(ctx.db, merchant_id: ctx.merchant!.id, id: id).to_api)
          end
        end

        sig { params(app: T.class_of(App)).void }
        def self.register_writes(app)
          app.post '/v1/payment_intents' do
            T.bind(self, App)
            respond(Payments::Operations.create(ctx, Routes::PaymentIntents.create_input(api_params)).to_api)
          end

          app.post '/v1/payment_intents/:id/confirm' do |id|
            T.bind(self, App)
            p = api_params.permit!('payment_method')
            input = Payments::Confirm::Input.new(intent_id: id, payment_method: Routes::PaymentIntents.payment_method(p))
            respond(Payments::Operations.confirm(ctx, input).to_api)
          end

          app.post '/v1/payment_intents/:id/capture' do |id|
            T.bind(self, App)
            p = api_params.permit!('amount_to_capture')
            input = Payments::Capture::Input.new(intent_id: id,
                                                 amount_to_capture: p.integer(
                                                   'amount_to_capture', min: 1
                                                 ))
            respond(Payments::Operations.capture(ctx, input).to_api)
          end

          app.post '/v1/payment_intents/:id/cancel' do |id|
            T.bind(self, App)
            p = api_params.permit!('cancellation_reason')
            reason = p.enum('cancellation_reason', Payments::Cancel::REASONS)
            respond(Payments::Operations.cancel(ctx, Payments::Cancel::Input.new(intent_id: id,
                                                                                 cancellation_reason: reason)).to_api)
          end
        end

        sig { params(ctx: Context, params: Params).returns(T::Hash[String, T.untyped]) }
        def self.list(ctx, params)
          limit = params.integer('limit', min: 1, max: LIST_LIMIT_MAX) || LIST_LIMIT_DEFAULT
          intents, more = Payments::PaymentIntents.list(ctx.db, merchant_id: ctx.merchant!.id, limit: limit,
                                                                starting_after: params.string('starting_after'))
          { 'object' => 'list', 'url' => '/v1/payment_intents', 'has_more' => more, 'data' => intents.map(&:to_api) }
        end

        sig { params(params: Params).returns(Payments::Create::Input) }
        def self.create_input(params)
          p = params.permit!('amount', 'currency', 'payment_method', 'capture_method', 'customer_email',
                             free_form: %w[metadata risk_fields])
          currency = T.must(p.string('currency', required: true)).downcase
          raise Errors::InvalidRequestError.invalid_parameter('currency', 'is not a supported currency.') unless
            Currency.known?(currency)

          Payments::Create::Input.new(
            amount: T.must(p.integer('amount', required: true, min: 1, max: 99_999_999)), currency: currency,
            payment_method: payment_method(p),
            capture_method: p.enum('capture_method', Payments::PaymentIntent::CAPTURE_METHODS) || 'automatic',
            customer_email: p.string('customer_email', max_length: 512), metadata: p.metadata,
            risk_fields: risk_fields(p)
          )
        end

        # A test token, or nil. There are no real cards: anything else is unknown.
        sig { params(params: Params).returns(T.nilable(String)) }
        def self.payment_method(params)
          id = params.string('payment_method')
          return nil if id.nil?
          return id if PaymentMethods.known?(id)

          raise Errors::InvalidRequestError.new("No such PaymentMethod: '#{id}'", code: 'resource_missing',
                                                                                  param: 'payment_method')
        end

        # Passed through to RiskGate as sent. It only has to be an object.
        sig { params(params: Params).returns(T::Hash[String, T.untyped]) }
        def self.risk_fields(params)
          value = params['risk_fields']
          return {} if value.nil? || value == ''
          unless value.is_a?(Hash)
            raise Errors::InvalidRequestError.invalid_parameter('risk_fields',
                                                                'must be an object.')
          end

          value
        end
      end
    end
  end
end
