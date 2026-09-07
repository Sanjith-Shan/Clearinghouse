# typed: true
# frozen_string_literal: true

module ClearinghouseClient
  # Thin helpers over Client#request, one class per API resource. Each method returns
  # the response body as a plain Hash; call Client#request directly when you need
  # the Response (request id, replay flag, attempts).
  #
  # Mutating methods take `idempotency_key:` (generated per call when omitted) and every
  # method takes `api_version:`, both passed through to Client#request. Request
  # parameters can be a Hash or keywords, so `create(amount: 2000, currency: 'usd')`
  # and `create({ amount: 2000, currency: 'usd' }, idempotency_key: 'order-6735')` both
  # work; the two option names are therefore not usable as request parameters.
  module Resources
    # Shared plumbing: paths, id checks and auto-pagination.
    class Base
      extend T::Sig

      sig { params(client: Client, path: String).void }
      def initialize(client, path)
        @client = client
        @path = path
      end

      private

      sig do
        params(method: Symbol, path: String, params: T.nilable(T::Hash[T.untyped, T.untyped]),
               idempotency_key: T.nilable(String), api_version: T.nilable(String))
          .returns(T::Hash[String, T.untyped])
      end
      def call(method, path, params, idempotency_key: nil, api_version: nil)
        @client.request(method, path, params: params, idempotency_key: idempotency_key, api_version: api_version).data
      end

      # Keys as strings, so a Hash and keywords naming the same parameter cannot both
      # be sent; the keyword wins.
      sig { params(params: T::Hash[T.untyped, T.untyped], inline: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def merged(params, inline)
        params.transform_keys(&:to_s).merge(inline.transform_keys(&:to_s))
      end

      # An empty or non-string id would turn `retrieve(id)` into a request for the
      # collection, or for some other path, so it is refused before any request.
      sig { params(id: T.untyped, suffix: T.nilable(String)).returns(String) }
      def member(id, suffix = nil)
        raise ArgumentError, "id must be a non-empty String, got #{id.inspect}" unless id.is_a?(String) && !id.empty?

        escaped = URI.encode_www_form_component(id).gsub('+', '%20')
        suffix ? "#{@path}/#{escaped}/#{suffix}" : "#{@path}/#{escaped}"
      end

      # Every object in the list, fetching pages lazily as the caller consumes them.
      # Follows `starting_after` (the last id on the page), or `ending_before` (the
      # first id) when the caller started with `ending_before`, until `has_more` is
      # false. An empty page ends it even if the server claims there is more, so a
      # server bug cannot turn this into an infinite loop.
      sig { params(params: T::Hash[T.untyped, T.untyped], api_version: T.nilable(String)).returns(T::Enumerator[T.untyped]) }
      def paginate(params, api_version)
        page_params = params.transform_keys(&:to_s)
        backwards = page_params.key?('ending_before')
        Enumerator.new do |yielder|
          loop do
            page = call(:get, @path, page_params, api_version: api_version)
            data = page.fetch('data', [])
            data.each { |object| yielder << object }
            break if !page['has_more'] || data.empty?

            page_params = if backwards
                            page_params.merge('ending_before' => data.first.fetch('id'))
                          else
                            page_params.merge('starting_after' => data.last.fetch('id'))
                          end
          end
        end
      end
    end

    # A resource with a list endpoint, GET /v1/<resource>, and auto-pagination over it.
    class Listable < Base
      sig do
        params(params: T::Hash[T.untyped, T.untyped], api_version: T.nilable(String), inline: T.untyped)
          .returns(T::Hash[String, T.untyped])
      end
      def list(params = {}, api_version: nil, **inline)
        call(:get, @path, merged(params, inline), api_version: api_version)
      end

      # `client.payment_intents.each(limit: 100) { |intent| ... }`, or without a block
      # an Enumerator (`.first(250)`, `.lazy.select`, ...).
      sig do
        params(params: T::Hash[T.untyped, T.untyped], api_version: T.nilable(String), inline: T.untyped,
               block: T.nilable(T.proc.params(object: T::Hash[String, T.untyped]).void)).returns(T.untyped)
      end
      def each(params = {}, api_version: nil, **inline, &block)
        enumerator = paginate(merged(params, inline), api_version)
        return enumerator unless block

        enumerator.each(&block)
      end
    end

    # /v1/payment_intents
    class PaymentIntents < Listable
      sig do
        params(params: T::Hash[T.untyped, T.untyped], idempotency_key: T.nilable(String),
               api_version: T.nilable(String), inline: T.untyped).returns(T::Hash[String, T.untyped])
      end
      def create(params = {}, idempotency_key: nil, api_version: nil, **inline)
        call(:post, @path, merged(params, inline), idempotency_key: idempotency_key, api_version: api_version)
      end

      sig { params(id: String, api_version: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
      def retrieve(id, api_version: nil)
        call(:get, member(id), nil, api_version: api_version)
      end

      sig do
        params(id: String, params: T::Hash[T.untyped, T.untyped], idempotency_key: T.nilable(String),
               api_version: T.nilable(String), inline: T.untyped).returns(T::Hash[String, T.untyped])
      end
      def confirm(id, params = {}, idempotency_key: nil, api_version: nil, **inline)
        call(:post, member(id, 'confirm'), merged(params, inline), idempotency_key: idempotency_key,
                                                                   api_version: api_version)
      end

      sig do
        params(id: String, params: T::Hash[T.untyped, T.untyped], idempotency_key: T.nilable(String),
               api_version: T.nilable(String), inline: T.untyped).returns(T::Hash[String, T.untyped])
      end
      def capture(id, params = {}, idempotency_key: nil, api_version: nil, **inline)
        call(:post, member(id, 'capture'), merged(params, inline), idempotency_key: idempotency_key,
                                                                   api_version: api_version)
      end

      sig do
        params(id: String, params: T::Hash[T.untyped, T.untyped], idempotency_key: T.nilable(String),
               api_version: T.nilable(String), inline: T.untyped).returns(T::Hash[String, T.untyped])
      end
      def cancel(id, params = {}, idempotency_key: nil, api_version: nil, **inline)
        call(:post, member(id, 'cancel'), merged(params, inline), idempotency_key: idempotency_key,
                                                                  api_version: api_version)
      end
    end

    # /v1/refunds and /v1/payouts: create and retrieve.
    class CreateRetrieve < Base
      sig do
        params(params: T::Hash[T.untyped, T.untyped], idempotency_key: T.nilable(String),
               api_version: T.nilable(String), inline: T.untyped).returns(T::Hash[String, T.untyped])
      end
      def create(params = {}, idempotency_key: nil, api_version: nil, **inline)
        call(:post, @path, merged(params, inline), idempotency_key: idempotency_key, api_version: api_version)
      end

      sig { params(id: String, api_version: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
      def retrieve(id, api_version: nil)
        call(:get, member(id), nil, api_version: api_version)
      end
    end

    # /v1/webhook_endpoints
    class WebhookEndpoints < Listable
      sig do
        params(params: T::Hash[T.untyped, T.untyped], idempotency_key: T.nilable(String),
               api_version: T.nilable(String), inline: T.untyped).returns(T::Hash[String, T.untyped])
      end
      def create(params = {}, idempotency_key: nil, api_version: nil, **inline)
        call(:post, @path, merged(params, inline), idempotency_key: idempotency_key, api_version: api_version)
      end

      sig do
        params(id: String, idempotency_key: T.nilable(String), api_version: T.nilable(String))
          .returns(T::Hash[String, T.untyped])
      end
      def delete(id, idempotency_key: nil, api_version: nil)
        call(:delete, member(id), nil, idempotency_key: idempotency_key, api_version: api_version)
      end
    end

    # /v1/events: list only; events are created by the server.
    class Events < Listable; end

    # A single object with no id: /v1/balance, /v1/account.
    class Singleton < Base
      sig { params(api_version: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
      def retrieve(api_version: nil)
        call(:get, @path, nil, api_version: api_version)
      end
    end
  end

  # The resource helpers, one fresh (stateless) helper per call.
  class Client
    extend T::Sig

    sig { returns(Resources::PaymentIntents) }
    def payment_intents = Resources::PaymentIntents.new(self, '/v1/payment_intents')

    sig { returns(Resources::CreateRetrieve) }
    def refunds = Resources::CreateRetrieve.new(self, '/v1/refunds')

    sig { returns(Resources::CreateRetrieve) }
    def payouts = Resources::CreateRetrieve.new(self, '/v1/payouts')

    sig { returns(Resources::WebhookEndpoints) }
    def webhook_endpoints = Resources::WebhookEndpoints.new(self, '/v1/webhook_endpoints')

    sig { returns(Resources::Events) }
    def events = Resources::Events.new(self, '/v1/events')

    sig { returns(Resources::Singleton) }
    def balance = Resources::Singleton.new(self, '/v1/balance')

    sig { returns(Resources::Singleton) }
    def account = Resources::Singleton.new(self, '/v1/account')
  end
end
