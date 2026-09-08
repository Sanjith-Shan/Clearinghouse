# typed: true
# frozen_string_literal: true

require 'cgi'
require 'json'
require 'sinatra/base'

module Clearinghouse
  module Api
    # The HTTP API. A modular Sinatra app that holds no global state: everything it
    # needs arrives in a Dependencies struct at construction. Build it with
    # `Api.rack_app(deps)`, which also wraps the request logger around it.
    #
    # Routes live in modules under api/routes/ that are Sinatra extensions
    # (`self.registered(app)`), registered at the bottom of this class. A route block
    # starts with `T.bind(self, Api::App)` and then uses the helpers below:
    # `ctx`, `api_params`, `respond`.
    class App < Sinatra::Base
      extend T::Sig

      # A JSON API with bearer keys: no cookies, so no CSRF, session or frame
      # protection to buy. Errors are rendered by us, never by Sinatra's HTML pages.
      set :protection, false
      set :host_authorization, { permitted_hosts: [] }
      set :method_override, false
      set :show_exceptions, false
      set :raise_errors, false
      set :dump_errors, false
      set :x_cascade, false
      set :default_content_type, 'application/json'

      sig { params(deps: Dependencies, app: T.untyped).void }
      def initialize(deps, app = nil)
        super(app)
        @deps = deps
        @ctx = T.let(nil, T.nilable(Context))
        @api_params = T.let(nil, T.nilable(Params))
      end

      sig { returns(Dependencies) }
      attr_reader :deps

      before do
        T.bind(self, App)
        @ctx = Context.new(
          deps: @deps,
          request_id: env.fetch(RequestLogger::REQUEST_ID) { Ids.generate('req') },
          http_method: request.request_method,
          path: request.path_info,
          idempotency_key: request.get_header('HTTP_IDEMPOTENCY_KEY'),
          api_version: @deps.versioning.latest
        )
        merchant = authenticate_request if requires_secret_key?
        resolve_api_version(merchant&.api_version)
      end

      # Routes under /v1 that do not take a merchant's secret key. Everything else
      # under /v1 does, checked here before routing so no route can forget it. (An
      # unknown /v1 path without a key is therefore a 401, not a 404, as in Stripe.)
      UNAUTHENTICATED = [%w[POST /v1/merchants]].freeze

      sig { returns(T::Boolean) }
      def requires_secret_key?
        path = request.path_info.to_s
        return false unless path.start_with?('/v1/')

        UNAUTHENTICATED.none?([request.request_method, path])
      end

      sig { returns(Merchant) }
      def authenticate_request
        merchant = Auth.merchant!(@deps.db, request.get_header('HTTP_AUTHORIZATION'))
        ctx.merchant = merchant
        env[RequestLogger::MERCHANT] = merchant.id
        merchant
      end

      # The header wins over the merchant's pin, and an unknown header value is an
      # error rather than a silent fallback: a client that asked for a version must
      # not get a different shape than it expects.
      sig { params(pinned: T.nilable(String)).void }
      def resolve_api_version(pinned)
        requested = request.get_header('HTTP_CLEARINGHOUSE_VERSION')
        if requested && !@deps.versioning.known?(requested)
          raise Errors::InvalidRequestError.new(
            "Invalid Clearinghouse-Version: #{requested}. Known versions: #{@deps.versioning.versions.join(', ')}.",
            code: 'api_version_invalid'
          )
        end
        ctx.api_version = requested || pinned || @deps.versioning.latest
        env[RequestLogger::API_VERSION] = ctx.api_version
      end

      sig { returns(Context) }
      def ctx
        T.must(@ctx)
      end

      # The request's parameters, parsed once. Named so it does not shadow
      # Sinatra's own `params`; route captures arrive as block arguments instead.
      sig { returns(Params) }
      def api_params
        @api_params ||= Params.from_request(request)
      end

      # Params for an endpoint after old callers' renamed parameters are rewritten
      # into the latest shape. Endpoints whose parameters have ever changed read
      # these; fingerprint `api_params.raw` for idempotency, which is what was sent.
      sig { params(endpoint: String).returns(Params) }
      def versioned_params(endpoint)
        Params.new(@deps.versioning.transform_request(endpoint, api_params.raw, ctx.api_version))
      end

      # Every successful response goes through here, so every endpoint is rendered
      # at the caller's version with its `expand[]` applied. `object` is always the
      # latest shape. `versioned: false` is for bodies that are not API resources.
      sig { params(object: T::Hash[String, T.untyped], status_code: Integer, versioned: T::Boolean).returns(String) }
      def respond(object, status_code: 200, versioned: true)
        body = versioned ? render_resource(object) : object
        status(status_code)
        headers['clearinghouse-version'] = ctx.api_version if versioned
        JSON.generate(body)
      end

      IDEMPOTENCY_KEY_MAX = 255

      # Runs a mutating operation under the request's Idempotency-Key (or a
      # generated one when there is none) and sends whatever the flow's key row
      # says to send: a fresh response, or the stored one for a replay, with
      # Idempotent-Replayed and Original-Request as Stripe sends them.
      sig { params(flow: Idempotency::Flow, input: T::Struct).returns(String) }
      def run_flow(flow, input)
        key = idempotency_key!
        runner = Idempotency::Runner.new(db: @deps.db, clock: @deps.clock, lock_timeout: @deps.idempotency_lock_timeout,
                                         crash_hook: @deps.crash_hook)
        request = Idempotency::Runner::Request.new(merchant_id: ctx.merchant!.id, key: key,
                                                   http_method: T.must(self.request.request_method),
                                                   path: T.must(self.request.path_info), params: api_params.raw,
                                                   request_id: ctx.request_id)
        renderer = FlowRenderer.new(ctx, api_version: ctx.api_version, expand: api_params.expand)
        result = runner.call(flow: flow, input: input, request: request, context: ctx, renderer: renderer)
        send_stored(result)
      rescue Idempotency::KeyReusedError
        raise Errors::IdempotencyKeyReusedError, T.must(key)
      rescue Idempotency::KeyInUseError, Idempotency::LockLostError
        raise Errors::IdempotencyKeyInUseError, key || 'generated'
      end

      sig { returns(T.nilable(String)) }
      def idempotency_key!
        key = ctx.idempotency_key
        return nil if key.nil?
        return key if !key.strip.empty? && key.length <= IDEMPOTENCY_KEY_MAX

        raise Errors::InvalidRequestError.new(
          "Idempotency-Key must be 1 to #{IDEMPOTENCY_KEY_MAX} characters.", code: 'idempotency_key_invalid'
        )
      end

      sig { params(result: Idempotency::Runner::Result).returns(String) }
      def send_stored(result)
        response = result.response
        status(response.status)
        response.headers.each { |name, value| headers[name] = value }
        if result.replayed
          headers['idempotent-replayed'] = 'true'
          headers['original-request'] = result.original_request_id
        end
        response.body
      end

      sig { params(object: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def render_resource(object)
        @deps.versioning.render(object, ctx.api_version, expand: api_params.expand, context: ctx)
      rescue Versioning::Engine::InvalidExpansionError => e
        raise Errors::InvalidRequestError.new("This property cannot be expanded (#{e.message}).",
                                              code: 'parameter_invalid', param: 'expand')
      end

      sig { params(error: Errors::Base).returns(String) }
      def render_error(error)
        status(error.http_status)
        retry_header = Errors.retry_header(error, method: request.request_method,
                                                  idempotency_key: request.get_header('HTTP_IDEMPOTENCY_KEY'))
        headers['clearinghouse-should-retry'] = retry_header if retry_header
        headers['www-authenticate'] = 'Bearer realm="Clearinghouse"' if error.is_a?(Errors::AuthenticationError)
        JSON.generate(error.to_h)
      end

      sig { params(error: Exception, request_id: String).void }
      def log_exception(error, request_id)
        log = @deps.log
        return unless log

        log.puts(JSON.generate({ 'level' => 'error', 'request_id' => request_id, 'exception' => error.class.name,
                                 'message' => error.message, 'backtrace' => error.backtrace&.first(10) }))
      end

      sig { returns(String) }
      def current_request_id
        env.fetch(RequestLogger::REQUEST_ID) { @ctx&.request_id || 'req_unknown' }
      end

      error Errors::Base do
        T.bind(self, App)
        render_error(env['sinatra.error'])
      end

      error Sinatra::NotFound do
        T.bind(self, App)
        render_error(Errors::NotFoundError.route(request.request_method, request.path_info))
      end

      # Sinatra parses the query and form body itself before routing and raises this
      # when Rack rejects them (`a=1&a[b]=2`). Its message arrives HTML-escaped.
      error Sinatra::BadRequest do
        T.bind(self, App)
        detail = CGI.unescapeHTML(env['sinatra.error'].message)
        render_error(Errors::InvalidRequestError.new("Malformed parameters: #{detail}", code: 'body_invalid'))
      end

      # Anything else is our bug. Log it with the request id; tell the caller only
      # the request id.
      error StandardError do
        T.bind(self, App)
        request_id = current_request_id
        log_exception(env['sinatra.error'], request_id)
        render_error(Errors::ApiError.new(request_id))
      end

      register Routes::Health
      register Routes::Merchants
      register Routes::PaymentIntents
      register Routes::Refunds
      register Routes::WebhookEndpoints
      register Routes::Events
      register Routes::Payouts
      register Routes::Reviews
      register Routes::Disputes
    end
  end
end
