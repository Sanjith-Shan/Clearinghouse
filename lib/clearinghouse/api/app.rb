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
          idempotency_key: request.get_header('HTTP_IDEMPOTENCY_KEY')
        )
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

      # Every successful response goes through here, so there is exactly one place
      # that serialises a resource.
      sig { params(object: T::Hash[String, T.untyped], status_code: Integer).returns(String) }
      def respond(object, status_code: 200)
        status(status_code)
        JSON.generate(object)
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
    end
  end
end
