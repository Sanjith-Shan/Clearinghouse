# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # Webhook endpoints, shaped after Stripe's /v1/webhook_endpoints.
      #
      # The URL goes through the same egress check a delivery does (SafeHttp#pin) when
      # it is registered or changed, so a merchant hears "that address is internal" at
      # once instead of watching every delivery fail. The signing secret is in the
      # response to create and to roll_secret, and never again.
      module WebhookEndpoints
        extend T::Sig

        EP = Webhooks::Endpoints

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          register_writes(app)
          register_roll_secret(app)
          register_reads(app)
        end

        sig { params(app: T.class_of(App)).void }
        def self.register_writes(app)
          app.post '/v1/webhook_endpoints' do
            T.bind(self, App)
            p = api_params.permit!('url', 'enabled_events', 'api_version', 'description')
            respond(WebhookEndpoints.create(ctx, p).to_api(include_secret: true))
          end

          app.post '/v1/webhook_endpoints/:id' do |id|
            T.bind(self, App)
            p = api_params.permit!('url', 'enabled_events', 'description', 'disabled')
            respond(WebhookEndpoints.update(ctx, WebhookEndpoints.find!(ctx, id), p).to_api)
          end

          app.delete '/v1/webhook_endpoints/:id' do |id|
            T.bind(self, App)
            api_params.permit!
            endpoint = WebhookEndpoints.find!(ctx, id)
            EP.delete(ctx.db, clock: ctx.clock, endpoint: endpoint)
            respond({ 'id' => endpoint.id, 'object' => 'webhook_endpoint', 'deleted' => true })
          end
        end

        sig { params(app: T.class_of(App)).void }
        def self.register_roll_secret(app)
          # Stripe's "roll secret". `expires_in` is how long the old secret keeps signing
          # alongside the new one, 0 to 86400 seconds. The default is the full 24 hours,
          # so a routine roll never drops a delivery; after a leak, pass 0.
          app.post '/v1/webhook_endpoints/:id/roll_secret' do |id|
            T.bind(self, App)
            p = api_params.permit!('expires_in')
            max = Webhooks::SecretRotation::MAX_OVERLAP
            rolled = EP.roll_secret(ctx.db, clock: ctx.clock, endpoint: WebhookEndpoints.find!(ctx, id),
                                            overlap: p.integer('expires_in', min: 0, max: max) || max)
            respond(rolled.to_api(include_secret: true))
          end
        end

        sig { params(app: T.class_of(App)).void }
        def self.register_reads(app)
          app.get '/v1/webhook_endpoints' do
            T.bind(self, App)
            p = api_params.permit!('limit', 'starting_after')
            endpoints, has_more = WebhookEndpoints.domain_errors do
              EP.list(ctx.db, ctx.merchant!.id, limit: p.integer('limit', min: 1, max: 100) || 10,
                                                starting_after: p.string('starting_after'))
            end
            respond({ 'object' => 'list', 'url' => '/v1/webhook_endpoints', 'has_more' => has_more,
                      'data' => endpoints.map(&:to_api) })
          end

          app.get '/v1/webhook_endpoints/:id' do |id|
            T.bind(self, App)
            api_params.permit!
            respond(WebhookEndpoints.find!(ctx, id).to_api)
          end
        end

        sig { params(ctx: Context, params: Params).returns(Webhooks::Endpoint) }
        def self.create(ctx, params)
          merchant = ctx.merchant!
          domain_errors do
            EP.create(ctx.db, clock: ctx.clock, merchant_id: merchant.id,
                              url: T.must(params.string('url', required: true, max_length: 2048)),
                              enabled_events: string_list(params, 'enabled_events'),
                              api_version: params.enum('api_version', ctx.deps.versioning.versions) ||
                                           merchant.api_version,
                              description: params.string('description', max_length: 500),
                              url_check: url_check(ctx))
          end
        end

        sig { params(ctx: Context, endpoint: Webhooks::Endpoint, params: Params).returns(Webhooks::Endpoint) }
        def self.update(ctx, endpoint, params)
          events = params.key?('enabled_events') ? string_list(params, 'enabled_events') : nil
          domain_errors do
            EP.update(ctx.db, clock: ctx.clock, endpoint: endpoint, url: params.string('url', max_length: 2048),
                              enabled_events: events, description: params.string('description', max_length: 500),
                              disabled: params.boolean('disabled'), url_check: url_check(ctx))
          end
        end

        sig { params(ctx: Context, id: String).returns(Webhooks::Endpoint) }
        def self.find!(ctx, id)
          EP.find(ctx.db, ctx.merchant!.id, id) || raise(Errors::NotFoundError.resource('webhook_endpoint', id))
        end

        sig { params(ctx: Context).returns(EP::UrlCheck) }
        def self.url_check(ctx)
          http = ctx.deps.webhook_http
          ->(url) { http.pin(url) }
        end

        # Translates the domain's validation errors into API errors.
        sig { type_parameters(:R).params(blk: T.proc.returns(T.type_parameter(:R))).returns(T.type_parameter(:R)) }
        def self.domain_errors(&blk)
          blk.call
        rescue EP::InvalidError => e
          raise Errors::InvalidRequestError.new(e.message, code: e.code, param: e.param)
        rescue EP::LimitError => e
          raise Errors::InvalidRequestError.new(e.message, code: 'webhook_endpoint_limit_reached')
        end

        # A required list: `name[]=a&name[]=b`, `name[0]=a`, or a JSON array of strings.
        sig { params(params: Params, name: String).returns(T::Array[String]) }
        def self.string_list(params, name)
          value = params[name]
          raise Errors::InvalidRequestError.missing_parameter(name) if value.nil? || value == ''

          list = case value
                 when Array then value
                 when Hash then value.sort_by { |key, _| key.to_s.to_i }.map(&:last)
                 else raise Errors::InvalidRequestError.invalid_parameter(name, 'must be an array of strings.')
                 end
          return list if list.all?(String)

          raise Errors::InvalidRequestError.invalid_parameter(name, 'must be an array of strings.')
        end
      end
    end
  end
end
