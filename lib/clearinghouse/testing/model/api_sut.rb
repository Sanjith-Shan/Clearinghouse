# typed: true
# frozen_string_literal: true

require 'json'
require 'rack/test'
require 'puma'
require 'puma/server'
require_relative '../../../../sim/lib/acquirer_sim'

module Clearinghouse
  module Testing
    module Model
      # The whole API as the system under test: every operation is an HTTP request
      # through the real Rack app (routes, params, errors, payments services, the
      # ledger), which talks to the real acquirer simulator over TCP. Nothing is
      # shadowed: outcomes come from the responses and the snapshot from the database
      # the app wrote.
      #
      # Wired today (payments M2): create_merchant, create_intent, confirm, capture,
      # cancel, refund, advance_clock (the test clock, then the authorization expiry
      # sweep). Still to wire, each raising NotImplementedError until its area lands:
      #
      # - payout               POST /v1/payouts {amount, currency}      (payouts)
      # - availability_sweep   the payouts area's availability worker    (payouts)
      # - resolve_dispute      simulator POST /admin/disputes/:id/resolve, then
      #                        the notification poller                   (disputes)
      # - settle               simulator POST /settlement_files for today, then the
      #                        reconciler                                (reconciler)
      # - advance_clock        must also run the notification poller (dispute.opened,
      #                        payout.paid, payout.failed)               (disputes, payouts)
      #
      # and two cards the generator leaves out until then:
      #
      # - pm_card_disputeFraudulent  its dispute opens through notifications
      # - pm_card_timeout            the payment stays `processing` behind a 503 until
      #                              M3's ambiguous-call handling resolves it
      class ApiSut
        extend T::Sig
        include Sut

        ADMIN_TOKEN = 'model_test_admin'
        API_TABLES = %w[refunds events payment_intents merchants].freeze

        sig do
          params(db: Sequel::Database, owner_db: Sequel::Database, acquirer_url: String,
                 reset_acquirer: T.proc.void).void
        end
        def initialize(db:, owner_db:, acquirer_url:, reset_acquirer:)
          @db = db
          @owner_db = owner_db
          @acquirer_url = acquirer_url
          @reset_acquirer = reset_acquirer
          @clock = T.let(Clock::Test.new(start: Policy::START), Clock::Test)
          @deps = T.let(build_deps, Api::Dependencies)
          @http = T.let(Rack::Test::Session.new(app), Rack::Test::Session)
          @ids = T.let({}, T::Hash[String, String]) # symbolic name => real id
          @keys = T.let({}, T::Hash[String, String]) # merchant name => secret key
          @intent_merchants = T.let({}, T::Hash[String, String])
        end

        sig { override.returns(T::Array[Symbol]) }
        def unsupported_operations
          %i[payout availability_sweep resolve_dispute settle]
        end

        sig { override.returns(T::Array[String]) }
        def unsupported_payment_methods
          %w[pm_card_disputeFraudulent pm_card_timeout]
        end

        sig { override.void }
        def reset!
          DbReset.ledger!(@owner_db, extra_tables: API_TABLES)
          @reset_acquirer.call
          @clock = Clock::Test.new(start: Policy::START)
          @deps = build_deps
          @http = Rack::Test::Session.new(app)
          [@ids, @keys, @intent_merchants].each(&:clear)
        end

        sig do
          override.params(merchant: String, fee_rate_scaled: Integer, fee_fixed: T::Hash[String, Integer])
                  .returns(Outcome)
        end
        def create_merchant(merchant:, fee_rate_scaled:, fee_fixed:)
          body = { name: merchant, fee_percent: Merchants.percent_string(fee_rate_scaled), fee_fixed: fee_fixed }
          status, json = request(:post, '/v1/merchants', body, auth: ADMIN_TOKEN)
          return error(json) unless status == 201

          @ids[merchant] = json.fetch('id')
          @keys[merchant] = json.fetch('secret_key')
          Outcome.success
        end

        sig do
          override.params(intent: String, merchant: String, amount: Integer, currency: String,
                          capture_method: String, payment_method: T.nilable(String)).returns(Outcome)
        end
        def create_intent(intent:, merchant:, amount:, currency:, capture_method:, payment_method: nil)
          # No key for a merchant that was never created: the request could not be
          # made at all, which is what resource_missing means to the model.
          key = @keys[merchant]
          return Outcome.error('resource_missing') unless key

          body = { amount: amount, currency: currency, capture_method: capture_method,
                   payment_method: payment_method }.compact
          status, json = request(:post, '/v1/payment_intents', body, auth: key)
          return error(json) unless status == 200

          @ids[intent] = json.fetch('id')
          @intent_merchants[intent] = merchant
          Outcome.success(status: json.fetch('status'), amount: json.fetch('amount'))
        end

        sig { override.params(intent: String, payment_method: String).returns(Outcome) }
        def confirm(intent:, payment_method:)
          on_intent(intent, 'confirm', payment_method: payment_method)
        end

        sig { override.params(intent: String, amount: T.nilable(Integer)).returns(Outcome) }
        def capture(intent:, amount: nil)
          on_intent(intent, 'capture', { amount_to_capture: amount }.compact)
        end

        sig { override.params(intent: String).returns(Outcome) }
        def cancel(intent:)
          on_intent(intent, 'cancel', {})
        end

        sig { override.params(refund: String, intent: String, amount: T.nilable(Integer)).returns(Outcome) }
        def refund(refund:, intent:, amount: nil)
          body = { payment_intent: @ids.fetch(intent, intent), amount: amount }.compact
          status, json = request(:post, '/v1/refunds', body, auth: key_for(intent))
          return error(json) unless status == 200

          @ids[refund] = json.fetch('id')
          # A refund the acquirer refused is still a 200, with status failed.
          Outcome.success(amount: json.fetch('amount'), status: json.fetch('status'))
        end

        sig do
          override.params(payout: String, merchant: String, currency: String, amount: T.nilable(Integer))
                  .returns(Outcome)
        end
        def payout(payout:, merchant:, currency:, amount: nil)
          raise NotImplementedError, 'TODO(payouts): POST /v1/payouts {amount, currency} as the merchant, ' \
                                     "record the po_ id under #{payout.inspect}"
        end

        sig { override.params(hours: Integer).returns(Outcome) }
        def advance_clock(hours:)
          return Outcome.error('parameter_invalid') unless hours.positive?

          @clock.advance(hours * Policy::HOUR)
          Payments::Expiry.sweep!(@deps)
          # TODO(disputes, payouts): run the notification poller here so dispute.opened,
          # payout.paid and payout.failed are delivered, as the model's advance_clock does.
          Outcome.success
        end

        sig { override.params(intent: String, outcome: String).returns(Outcome) }
        def resolve_dispute(intent:, outcome:)
          raise NotImplementedError, 'TODO(disputes): find the dispute on the simulator by the intent\'s ' \
                                     "acquirer_reference, POST /admin/disputes/:id/resolve {outcome: #{outcome}}, " \
                                     "then run the notification poller (intent #{intent})"
        end

        sig { override.returns(Outcome) }
        def settle
          raise NotImplementedError, 'TODO(reconciler): POST /settlement_files {date: today} on the simulator ' \
                                     'and reconcile the file'
        end

        sig { override.returns(Outcome) }
        def availability_sweep
          raise NotImplementedError, 'TODO(payouts): run the availability worker (Balances::Availability) ' \
                                     'at the test clock'
        end

        sig { override.returns(Snapshot) }
        def snapshot
          report = Ledger::Clearing.report(@db, as_of: @clock.now, slas: {})
          violations = Ledger::Invariants.check(@db).map { |v| "#{v.invariant}: #{v.detail}" } +
                       report.orphan_balances.map { |o| "orphan clearing balance: #{o.code} (#{o.currency})" }
          Snapshot.new(balances: balances, open_flows: report.open_flows.to_h do |f|
            [name_of(f.flow_id), f.unexplained]
          end,
                       intents: intent_amounts, ledger_violations: violations)
        end

        private

        sig { returns(Api::Dependencies) }
        def build_deps
          Api::Dependencies.new(db: @db, clock: @clock, admin_token: ADMIN_TOKEN,
                                acquirer: Acquirer::Client.new(clock: @clock, base_url: @acquirer_url))
        end

        sig { returns(T.untyped) }
        def app
          Api::RequestLogger.new(Api::App.new(@deps), @deps)
        end

        sig { params(intent: String).returns(String) }
        def key_for(intent)
          # An intent the sequence never created still needs some merchant's key for
          # the request, which then answers resource_missing.
          @keys.fetch(@intent_merchants.fetch(intent, @keys.keys.first.to_s), ADMIN_TOKEN)
        end

        sig { params(intent: String, action: String, body: T::Hash[Symbol, T.untyped]).returns(Outcome) }
        def on_intent(intent, action, body)
          status, json = request(:post, "/v1/payment_intents/#{@ids.fetch(intent, intent)}/#{action}", body,
                                 auth: key_for(intent))
          status == 200 ? intent_outcome(json) : error(json)
        end

        sig do
          params(method: Symbol, path: String, body: T::Hash[Symbol, T.untyped], auth: String)
            .returns([Integer, T::Hash[String, T.untyped]])
        end
        def request(method, path, body, auth:)
          @http.custom_request(method.to_s.upcase, path, JSON.generate(body),
                               'CONTENT_TYPE' => 'application/json', 'HTTP_AUTHORIZATION' => "Bearer #{auth}")
          response = @http.last_response
          [response.status, JSON.parse(response.body)]
        end

        sig { params(json: T::Hash[String, T.untyped]).returns(Outcome) }
        def intent_outcome(json)
          Outcome.success(status: json.fetch('status'), amount_received: json.fetch('amount_received'))
        end

        sig { params(json: T::Hash[String, T.untyped]).returns(Outcome) }
        def error(json)
          err = json.fetch('error')
          Outcome.error(err.fetch('code').to_s, decline_code: err['decline_code'])
        end

        sig { params(real: String).returns(String) }
        def name_of(real)
          @ids.key(real) || real
        end

        # Balances as the ledger holds them, with merchant ids mapped back to the
        # sequence's names.
        sig { returns(T::Hash[AccountKey, Integer]) }
        def balances
          merchants = @ids.select { |name, _| @keys.key?(name) }.invert
          @db[:account_balances].join(:ledger_accounts, id: :account_id).exclude(balance: 0)
                                .select(:code, :currency, :balance).all.to_h do |row|
            owner = row.fetch(:code)[/\Amerchant:([^:]+):/, 1]
            code = owner ? row.fetch(:code).sub(owner, merchants.fetch(owner, owner)) : row.fetch(:code)
            [[code, row.fetch(:currency)], Integer(row.fetch(:balance))]
          end
        end

        # Captured and refunded per payment, from the payment_intents rows the API
        # keeps (the ledger SUT reads the same from entries).
        sig { returns(T::Hash[String, IntentAmounts]) }
        def intent_amounts
          @db[:payment_intents].where(id: @ids.values).exclude(amount_received: 0)
                               .select(:id, :amount_received, :amount_refunded).all.to_h do |row|
            [name_of(row.fetch(:id)), IntentAmounts.new(captured: Integer(row.fetch(:amount_received)),
                                                        refunded: Integer(row.fetch(:amount_refunded)))]
          end
        end
      end

      # The acquirer simulator on a real Puma server on an ephemeral port, in this
      # process, the same way the payments specs run it (spec/sim/sim_helper.rb).
      class SimProcess
        extend T::Sig

        sig { returns(AcquirerSim::Simulator) }
        attr_reader :simulator

        sig { void }
        def initialize
          @simulator = T.let(AcquirerSim::Simulator.new, AcquirerSim::Simulator)
          @server = T.let(Puma::Server.new(AcquirerSim::App.new(simulator: @simulator), nil,
                                           min_threads: 1, max_threads: 4, log_writer: Puma::LogWriter.null),
                          Puma::Server)
          @server.add_tcp_listener('127.0.0.1', 0)
          @server.run
        end

        sig { returns(String) }
        def url
          "http://127.0.0.1:#{@server.connected_ports.first}"
        end

        sig { void }
        def stop
          @server.stop(true)
        end
      end
    end
  end
end
