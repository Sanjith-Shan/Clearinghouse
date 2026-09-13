# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # Reading the events outbox: GET /v1/events and GET /v1/events/:id, rendered at the
      # caller's API version like any other response, and the manual webhook resend.
      #
      # Stripe freezes an event's shape at the account version current when it was
      # created. Here the stored event is always the latest shape and every reader gets
      # it at their own version, the same rule webhook delivery follows per endpoint.
      # One rule for both paths is easier to reason about, and the golden files cover it.
      module Events
        extend T::Sig

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          app.get '/v1/events' do
            T.bind(self, App)
            p = api_params.permit!('limit', 'starting_after', 'type')
            rows, has_more = Events.page(ctx, limit: p.integer('limit', min: 1, max: 100) || 10,
                                              starting_after: p.string('starting_after'), type: p.string('type'))
            respond({ 'object' => 'list', 'url' => '/v1/events', 'has_more' => has_more,
                      'data' => rows.map { |row| Events.envelope(ctx, row) } })
          end

          app.get '/v1/events/:id' do |id|
            T.bind(self, App)
            api_params.permit!
            respond(Events.envelope(ctx, Events.find!(ctx, id)))
          end

          # Manual resend of one event to one endpoint, like
          # `stripe events resend <event> --webhook-endpoint=<endpoint>`. Returns the
          # delivery, which a worker picks up as soon as one is free.
          app.post '/v1/events/:id/retry' do |id|
            T.bind(self, App)
            p = api_params.permit!('webhook_endpoint')
            respond(Webhooks::Deliveries.to_api(Events.resend(ctx, Events.find!(ctx, id), p)))
          end
        end

        sig do
          params(ctx: Context, event: T::Hash[Symbol, T.untyped], params: Params).returns(T::Hash[Symbol, T.untyped])
        end
        def self.resend(ctx, event, params)
          endpoint_id = T.must(params.string('webhook_endpoint', required: true))
          endpoint = Webhooks::Endpoints.find(ctx.db, ctx.merchant!.id, endpoint_id) ||
                     raise(Errors::NotFoundError.resource('webhook_endpoint', endpoint_id, param: 'webhook_endpoint'))
          Webhooks::Deliveries.resend!(ctx.db, clock: ctx.clock, event: event, endpoint: endpoint)
        rescue Webhooks::Deliveries::Error => e
          raise Errors::InvalidRequestError.new(e.message, code: 'webhook_resend_refused', param: 'webhook_endpoint')
        end

        sig { params(ctx: Context, id: String).returns(T::Hash[Symbol, T.untyped]) }
        def self.find!(ctx, id)
          ctx.db[:events].where(merchant_id: ctx.merchant!.id, id: id).first ||
            raise(Errors::NotFoundError.resource('event', id))
        end

        # Newest first by outbox order. `seq` is the order events were written, which
        # is also what a merchant paging backwards through history expects.
        sig do
          params(ctx: Context, limit: Integer, starting_after: T.nilable(String), type: T.nilable(String))
            .returns([T::Array[T::Hash[Symbol, T.untyped]], T::Boolean])
        end
        def self.page(ctx, limit:, starting_after:, type:)
          scope = ctx.db[:events].where(merchant_id: ctx.merchant!.id)
          scope = scope.where(type: type) if type
          if starting_after
            seq = find!(ctx, starting_after)[:seq]
            scope = scope.where { Sequel[:seq] < seq }
          end
          rows = scope.order(Sequel.desc(:seq)).limit(limit + 1).all
          [rows.first(limit), rows.length > limit]
        end

        # The envelope says which version it is rendered at; `respond` does the walk.
        sig { params(ctx: Context, row: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
        def self.envelope(ctx, row)
          Clearinghouse::Events.envelope(row).merge('api_version' => ctx.api_version)
        end
      end
    end
  end
end
