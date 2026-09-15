# typed: true
# frozen_string_literal: true

require 'json'
require_relative '../../clearinghouse'

module Clearinghouse
  module Experiments
    # The two confirm implementations experiment 1 (the retry storm) measures
    # Clearinghouse against. They exist to be measured, and they are wrong on
    # purpose: docs/design/storm.md gives the interleaving that breaks each one.
    #
    #   POST /experiments/none/v1/payment_intents/:id/confirm   ignores Idempotency-Key
    #   POST /experiments/naive/v1/payment_intents/:id/confirm  look up the key, do the
    #                                                           work, insert the key: no lock
    #
    # Both run the same confirm steps as Payments::Flows::ConfirmIntent (Confirm.lock!,
    # record_risk!, authorize, record_authorization!, apply_approval!), in the same order,
    # each in its own SERIALIZABLE transaction, with the same acquirer key
    # (PaymentIntent#authorization_key) and the same response rendering. What they lack is
    # the idempotency layer: no key row held for the length of the request, no recovery
    # points, no resume, no ownership of the intent across steps.
    #
    # Guarded twice: production's config.ru never loads this file, and `rack_app`
    # refuses to build unless CLEARINGHOUSE_ENV is `experiment`. Only the storm's own
    # rackup (sim/experiments/storm.ru) builds it.
    module StormBaselines
      extend T::Sig

      ENVIRONMENT = 'experiment'

      # Where the naive implementation keeps its keys. Not in db/migrations: it is not
      # part of the product's schema. `ensure_table!` creates it in the experiment's
      # database (and the test database), as the owner.
      NAIVE_TABLE = :experiment_naive_idempotency_keys

      class NotAllowedError < Clearinghouse::Error; end

      # What a baseline does when the acquirer's answer is lost (Unknown) or it is down
      # (Unavailable). Without recovery points nothing can finish the attempt later, so
      # it has two choices, and the storm can measure either:
      #
      # - Fail: end the attempt, the intent goes back to requires_payment_method, so the
      #   customer's retry can pay. If the lost answer was an approval, the retry charges
      #   the card a second time under the next attempt's key.
      # - Hold: leave the intent processing. Nothing charges twice, and nothing ever
      #   records the charge that did happen: every retry is refused.
      class OnUnknown < T::Enum
        enums do
          Fail = new('fail')
          Hold = new('hold')
        end
      end

      sig { params(owner_db: Sequel::Database).void }
      def self.ensure_table!(owner_db)
        owner_db.run(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{NAIVE_TABLE} (
            merchant_id text NOT NULL,
            key text NOT NULL,
            status integer NOT NULL,
            body text NOT NULL,
            headers text NOT NULL,
            request_id text NOT NULL,
            created_at timestamptz NOT NULL,
            PRIMARY KEY (merchant_id, key)
          )
        SQL
        owner_db.run("GRANT SELECT, INSERT ON #{NAIVE_TABLE} TO clearinghouse_app")
      end

      # The API with the two baselines mounted beside the real routes.
      sig do
        params(deps: Api::Dependencies, on_unknown: OnUnknown, env: T::Hash[String, T.nilable(String)])
          .returns(Api::RequestLogger)
      end
      def self.rack_app(deps, on_unknown: OnUnknown::Fail, env: ENV.to_h)
        unless env['CLEARINGHOUSE_ENV'] == ENVIRONMENT
          raise NotAllowedError, "the storm baselines are only mounted when CLEARINGHOUSE_ENV is #{ENVIRONMENT}"
        end

        Api::RequestLogger.new(App.new(deps, on_unknown), deps)
      end

      # Confirm without the idempotency layer: the same steps, run straight through.
      # Returns the response to send, or raises an error that is not final (a 5xx),
      # which the app renders exactly as it renders the real endpoint's.
      module UnprotectedConfirm
        extend T::Sig

        C = Payments::Confirm

        sig do
          params(ctx: Api::Context, input: C::Input, renderer: Api::FlowRenderer,
                 on_unknown: OnUnknown).returns(Idempotency::Response)
        end
        def self.call(ctx, input, renderer, on_unknown)
          run(ctx, input, renderer, on_unknown)
        rescue StandardError => e
          renderer.error_response(e) || raise
        end

        sig do
          params(ctx: Api::Context, input: C::Input, renderer: Api::FlowRenderer,
                 on_unknown: OnUnknown).returns(Idempotency::Response)
        end
        def self.run(ctx, input, renderer, on_unknown)
          db = ctx.db
          id = input.intent_id
          intent = tx(db) { C.lock!(db, ctx, input) }
          risk = C.assess_risk(ctx, intent)
          blocked = tx(db) { C.record_risk!(db, ctx, id, risk) }
          return T.must(renderer.error_response(blocked)) if blocked

          outcome = C.authorize(ctx, find(ctx, id))
          case outcome
          when Acquirer::Unknown, Acquirer::Unavailable
            tx(db) { fail_attempt!(db, ctx, id) } if on_unknown == OnUnknown::Fail
            Payments::Support.acquirer_unavailable!(outcome)
          end
          recorded = tx(db) { C.record_authorization!(db, ctx, id, outcome) }
          if outcome.is_a?(Acquirer::Declined)
            return T.must(renderer.error_response(Payments::Errors.card_error(T.must(recorded.last_payment_error))))
          end

          tx(db) { C.apply_approval!(db, ctx, id) }
          renderer.render(find(ctx, id).to_api)
        end
        private_class_method :run

        # Ends the attempt as if the card had been declined, keeping the payment method
        # (the card was not refused), so the next confirm starts attempt N + 1.
        sig { params(db: Sequel::Database, ctx: Api::Context, id: String).void }
        def self.fail_attempt!(db, ctx, id)
          intent = Payments::PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: id)
          to = Payments::Errors.transition!(intent, Payments::StateMachine::Event::AuthorizationDeclined)
          failed = Payments::Support.save!(db, ctx, intent, intent.copy(
                                                              status: to,
                                                              last_payment_error: {
                                                                'code' => 'acquirer_unavailable', 'decline_code' => nil,
                                                                'message' => 'The card network did not answer.'
                                                              }
                                                            ))
          Payments::Support.emit!(db, ctx, 'payment_intent.payment_failed', failed.to_api)
        end
        private_class_method :fail_attempt!

        sig { params(ctx: Api::Context, id: String).returns(Payments::PaymentIntent) }
        def self.find(ctx, id)
          Payments::PaymentIntents.find!(ctx.db, merchant_id: ctx.merchant!.id, id: id)
        end
        private_class_method :find

        sig do
          type_parameters(:R).params(db: Sequel::Database, block: T.proc.returns(T.type_parameter(:R)))
                             .returns(T.type_parameter(:R))
        end
        def self.tx(db, &block) # rubocop:disable Style/ArgumentsForwarding,Naming/BlockForwarding
          Idempotency::Serializable.transaction(db, &block) # rubocop:disable Style/ArgumentsForwarding,Naming/BlockForwarding
        end
        private_class_method :tx
      end

      # Check-then-insert. The lookup takes no lock and marks nothing, so every request
      # that looks before the first one has inserted finds nothing and does the work.
      # What is stored follows the real rule (FlowRenderer#error_response): 2xx and final
      # 4xx, never a 5xx.
      module NaiveStore
        extend T::Sig

        # The stored response and the id of the request that stored it.
        sig do
          params(db: Sequel::Database, merchant_id: String, key: String)
            .returns(T.nilable([Idempotency::Response, String]))
        end
        def self.find(db, merchant_id, key)
          row = db[NAIVE_TABLE].where(merchant_id: merchant_id, key: key).first
          return nil unless row

          [Idempotency::Response.new(status: Integer(row.fetch(:status)), body: String(row.fetch(:body)),
                                     headers: JSON.parse(String(row.fetch(:headers)))),
           String(row.fetch(:request_id))]
        end

        # A second insert for the key loses on the primary key; the naive version keeps
        # its own answer and sends it anyway.
        sig do
          params(db: Sequel::Database, merchant_id: String, key: String, response: Idempotency::Response,
                 request_id: String, now: Time).void
        end
        def self.insert(db, merchant_id:, key:, response:, request_id:, now:)
          db[NAIVE_TABLE].insert(merchant_id: merchant_id, key: key, status: response.status, body: response.body,
                                 headers: JSON.generate(response.headers), request_id: request_id, created_at: now)
        rescue Sequel::UniqueConstraintViolation
          nil
        end
      end

      # Api::App plus the baseline routes. Sinatra runs the parent's filters and error
      # handlers first, so these requests are logged, versioned and rendered like any other.
      class App < Api::App
        extend T::Sig

        sig { params(deps: Api::Dependencies, on_unknown: OnUnknown, app: T.untyped).void }
        def initialize(deps, on_unknown, app = nil)
          super(deps, app)
          @on_unknown = on_unknown
        end

        # The parent authenticates only /v1/; these paths need the same.
        before '/experiments/*' do
          T.bind(self, App)
          merchant = authenticate_request
          resolve_api_version(merchant.api_version)
        end

        sig { params(id: String).returns(Payments::Confirm::Input) }
        def confirm_input(id)
          p = api_params.permit!('payment_method')
          Payments::Confirm::Input.new(intent_id: id, payment_method: Api::Routes::PaymentIntents.payment_method(p))
        end

        sig { returns(Api::FlowRenderer) }
        def renderer
          Api::FlowRenderer.new(ctx, api_version: ctx.api_version, expand: api_params.expand)
        end

        sig { params(response: Idempotency::Response, original: T.nilable(String)).returns(String) }
        def send_response(response, original: nil)
          send_stored(Idempotency::Runner::Result.new(response: response, replayed: !original.nil?,
                                                      original_request_id: original || ctx.request_id))
        end

        post '/experiments/none/v1/payment_intents/:id/confirm' do |id|
          T.bind(self, App)
          input = confirm_input(id)
          send_response(UnprotectedConfirm.call(ctx, input, renderer, @on_unknown))
        end

        post '/experiments/naive/v1/payment_intents/:id/confirm' do |id|
          T.bind(self, App)
          input = confirm_input(id)
          key = idempotency_key!
          merchant_id = ctx.merchant!.id
          stored = key && NaiveStore.find(ctx.db, merchant_id, key)
          next send_response(stored.first, original: stored.last) if stored

          response = UnprotectedConfirm.call(ctx, input, renderer, @on_unknown)
          if key
            NaiveStore.insert(ctx.db, merchant_id: merchant_id, key: key, response: response,
                                      request_id: ctx.request_id, now: ctx.clock.now)
          end
          send_response(response)
        end
      end
    end
  end
end
