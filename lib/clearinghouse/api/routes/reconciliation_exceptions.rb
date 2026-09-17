# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # Reconciliation exceptions, for operators. They are the platform's books, not a
      # merchant's, so these routes take the admin token. There is no Stripe
      # equivalent to mirror; the shape follows Stripe's conventions (list objects,
      # `starting_after`, typed errors).
      module ReconciliationExceptions
        extend T::Sig

        LIST_LIMIT_DEFAULT = 20
        LIST_LIMIT_MAX = 100
        STATUSES = %w[open resolved].freeze

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          app.get '/v1/reconciliation_exceptions' do
            T.bind(self, App)
            operator!
            p = api_params.permit!('status', 'reason', 'flow', 'limit', 'starting_after')
            respond(Routes::ReconciliationExceptions.list(ctx, p))
          end

          app.get '/v1/reconciliation_exceptions/:id' do |id|
            T.bind(self, App)
            operator!
            api_params.permit!
            found = Reconciliation::Exceptions.find(ctx.db, id)
            raise Errors::NotFoundError.resource('reconciliation exception', id) unless found

            respond(found.to_api)
          end

          app.post '/v1/reconciliation_exceptions/:id/resolve' do |id|
            T.bind(self, App)
            operator!
            p = api_params.permit!('note', 'action', 'ledger_transaction')
            respond(Routes::ReconciliationExceptions.resolve(ctx, id, p).to_api)
          end
        end

        sig { params(ctx: Context, params: Params).returns(T::Hash[String, T.untyped]) }
        def self.list(ctx, params)
          starting_after = params.string('starting_after', max_length: 64)
          found, more = Reconciliation::Exceptions.list(
            ctx.db, limit: params.integer('limit', min: 1, max: LIST_LIMIT_MAX) || LIST_LIMIT_DEFAULT,
                    status: params.enum('status', STATUSES), reason: params.enum('reason', Reconciliation::REASONS),
                    flow_id: params.string('flow', max_length: 64), starting_after: starting_after
          )
          { 'object' => 'list', 'url' => '/v1/reconciliation_exceptions', 'has_more' => more,
            'data' => found.map(&:to_api) }
        rescue Reconciliation::Exceptions::NotFoundError
          raise Errors::NotFoundError.resource('reconciliation exception', starting_after.to_s, param: 'starting_after')
        end

        sig do
          params(ctx: Context, id: String, params: Params).returns(Reconciliation::ReconciliationException)
        end
        def self.resolve(ctx, id, params)
          Reconciliation::Exceptions.resolve!(
            ctx.db, id, note: T.must(params.string('note', required: true, max_length: 2000)),
                        action: params.enum('action', Reconciliation::Exceptions::ACTIONS) || 'none',
                        ledger_transaction: params.integer('ledger_transaction', min: 1), clock: ctx.clock
          )
        rescue Reconciliation::Exceptions::NotFoundError
          raise Errors::NotFoundError.resource('reconciliation exception', id)
        rescue Reconciliation::Exceptions::AlreadyResolvedError => e
          raise Errors::InvalidRequestError.new(e.message, code: 'reconciliation_exception_resolved')
        rescue Reconciliation::Exceptions::InvalidResolutionError => e
          raise Errors::InvalidRequestError.new(e.message, code: 'resolution_invalid')
        end
      end
    end
  end
end
