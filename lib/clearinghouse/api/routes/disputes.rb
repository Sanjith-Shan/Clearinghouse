# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # Disputes, as the merchant sees them. They are created by the acquirer (through
      # the notification poller), never over the API. The one thing a merchant can do
      # is accept the loss, which Stripe's API calls closing the dispute.
      module Disputes
        extend T::Sig

        LIST_LIMIT_DEFAULT = 10
        LIST_LIMIT_MAX = 100

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          app.get '/v1/disputes' do
            T.bind(self, App)
            p = api_params.permit!('limit', 'starting_after')
            respond(Routes::Disputes.list(ctx, p))
          end

          app.get '/v1/disputes/:id' do |id|
            T.bind(self, App)
            api_params.permit!
            dispute = Clearinghouse::Disputes.find(ctx.db, merchant_id: ctx.merchant!.id, id: id)
            raise Errors::NotFoundError.resource('dispute', id) unless dispute

            respond(dispute.to_api)
          end

          app.post '/v1/disputes/:id/close' do |id|
            T.bind(self, App)
            api_params.permit!
            respond(Routes::Disputes.accept(ctx, id).to_api)
          end
        end

        sig { params(ctx: Context, params: Params).returns(T::Hash[String, T.untyped]) }
        def self.list(ctx, params)
          limit = params.integer('limit', min: 1, max: LIST_LIMIT_MAX) || LIST_LIMIT_DEFAULT
          starting_after = params.string('starting_after', max_length: 64)
          disputes, more = Clearinghouse::Disputes.list(ctx.db, merchant_id: ctx.merchant!.id, limit: limit,
                                                                starting_after: starting_after)
          { 'object' => 'list', 'url' => '/v1/disputes', 'has_more' => more, 'data' => disputes.map(&:to_api) }
        rescue Clearinghouse::Disputes::NotFoundError
          raise Errors::NotFoundError.resource('dispute', starting_after.to_s, param: 'starting_after')
        end

        sig { params(ctx: Context, id: String).returns(Clearinghouse::Disputes::Dispute) }
        def self.accept(ctx, id)
          Clearinghouse::Disputes::Service.new(clock: ctx.clock)
                                          .accept(ctx.db, merchant_id: ctx.merchant!.id, id: id,
                                                          request: ctx.event_request)
        rescue Clearinghouse::Disputes::NotFoundError
          raise Errors::NotFoundError.resource('dispute', id)
        rescue Clearinghouse::Disputes::AlreadyClosedError
          raise Errors::InvalidRequestError.new("This dispute was already won and can't be closed.",
                                                code: 'dispute_already_closed')
        end
      end
    end
  end
end
