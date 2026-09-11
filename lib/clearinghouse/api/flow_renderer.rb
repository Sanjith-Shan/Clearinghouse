# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    # How an idempotent flow's result becomes the bytes a client gets: the object
    # rendered at the request's API version with its expand[], or a final error.
    # Everything it needs is in `options`, which is stored with the key, so the
    # completer can render exactly what the original request would have.
    class FlowRenderer
      extend T::Sig
      include Idempotency::Renderer

      sig { params(ctx: Context, api_version: String, expand: T::Array[String]).void }
      def initialize(ctx, api_version:, expand:)
        @ctx = ctx
        @api_version = api_version
        @expand = expand
      end

      sig { params(ctx: Context, options: T::Hash[String, T.untyped]).returns(FlowRenderer) }
      def self.from_options(ctx, options)
        new(ctx, api_version: String(options.fetch('api_version')), expand: Array(options.fetch('expand')))
      end

      sig { override.params(object: T::Hash[String, T.untyped], status: Integer).returns(Idempotency::Response) }
      def render(object, status: 200)
        body = @ctx.deps.versioning.render(object, @api_version, expand: @expand, context: @ctx)
        Idempotency::Response.new(status: status, body: JSON.generate(body),
                                  headers: { 'clearinghouse-version' => @api_version })
      rescue Versioning::Engine::InvalidExpansionError => e
        raise Errors::InvalidRequestError.new("This property cannot be expanded (#{e.message}).",
                                              code: 'parameter_invalid', param: 'expand')
      end

      # Only errors that depend on nothing but the request are final: a 4xx whose
      # retry would fail the same way. A 409 for a busy object, a 429, and every
      # 5xx are not stored; the key is given back and a retry runs again.
      sig { override.params(error: StandardError).returns(T.nilable(Idempotency::Response)) }
      def error_response(error)
        return nil unless error.is_a?(Errors::Base)
        return nil if error.http_status >= 500 || error.retry_hint == Errors::RetryHint::Retry

        headers = {}
        retry_header = Errors.retry_header(error, method: 'POST', idempotency_key: nil)
        headers['clearinghouse-should-retry'] = retry_header if retry_header
        Idempotency::Response.new(status: error.http_status, body: JSON.generate(error.to_h), headers: headers)
      end

      sig { override.returns(T::Hash[String, T.untyped]) }
      def options
        { 'api_version' => @api_version, 'expand' => @expand }
      end
    end
  end
end
