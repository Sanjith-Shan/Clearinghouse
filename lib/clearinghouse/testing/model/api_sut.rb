# typed: true
# frozen_string_literal: true

require 'json'
require 'net/http'
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
      # Every operation is wired. Those that no endpoint performs call the pieces
      # bin/scheduler runs, directly and at the test clock, in the scheduler's order:
      #
      # - advance_clock        the clock, then the authorization expiry sweep, then
      #                        the notification poller (dispute.opened, payout.paid,
      #                        payout.failed)
      # - availability_sweep   Balances::Availability.release_due!
      # - resolve_dispute      the simulator's POST /admin/disputes/:id/resolve (the
      #                        card network's ruling), then the poller
      # - settle               Reconciliation::Ingestor#ingest for today's date
      #
      # One card is still left out: pm_card_timeout, whose confirm answers 503 and
      # leaves the payment `processing` until a retry resumes it, which a sequence
      # step does not do.
      class ApiSut
        extend T::Sig
        include Sut

        ADMIN_TOKEN = 'model_test_admin'
        # Tables the reset leaves alone: the migrator's.
        KEEP_TABLES = %w[schema_migrations schema_info].freeze

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
          []
        end

        sig { override.returns(T::Array[String]) }
        def unsupported_payment_methods
          %w[pm_card_timeout]
        end

        # Empties every table the API, the poller and the reconciler write.
        sig { override.void }
        def reset!
          tables = @owner_db.fetch("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map(:tablename)
          DbReset.ledger!(@owner_db, extra_tables: tables - KEEP_TABLES - DbReset::LEDGER_TABLES)
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
          key = @keys[merchant]
          return Outcome.error('resource_missing') unless key

          status, json = request(:post, '/v1/payouts', { amount: amount, currency: currency }.compact, auth: key)
          return error(json) unless status == 200

          @ids[payout] = json.fetch('id')
          Outcome.success(amount: json.fetch('amount'), status: json.fetch('status'))
        end

        sig { override.params(hours: Integer).returns(Outcome) }
        def advance_clock(hours:)
          return Outcome.error('parameter_invalid') unless hours.positive?

          @clock.advance(hours * Policy::HOUR)
          Payments::Expiry.sweep!(@deps)
          poll!
          Outcome.success
        end

        # The card network rules on the payment's dispute: the simulator's admin
        # endpoint, at the test clock, then a poll so dispute.closed is applied.
        sig { override.params(intent: String, outcome: String).returns(Outcome) }
        def resolve_dispute(intent:, outcome:)
          dispute = acquirer_dispute(intent)
          return Outcome.error('resource_missing') unless dispute

          resolve = Net::HTTP::Post.new("/admin/disputes/#{dispute.fetch('id')}/resolve")
          resolve['Content-Type'] = 'application/json'
          resolve.body = JSON.generate('outcome' => outcome)
          code, json = acquirer_json(resolve)
          # The simulator's errors are {"error": "<code>", "message": ...}.
          return Outcome.error(json.fetch('error').to_s) unless code == 200

          poll!
          Outcome.success(status: @db[:disputes].where(payment_intent: @ids.fetch(intent)).get(:status))
        end

        # Today's settlement file, reconciled.
        sig { override.returns(Outcome) }
        def settle
          result = Reconciliation::Ingestor.new(db: @db, client: T.must(@deps.acquirer), clock: @clock)
                                           .ingest(@clock.now.utc.to_date)
          raise Clearinghouse::Error, "settlement file unavailable: #{result.detail}" if result.status == 'unavailable'

          Outcome.success
        end

        sig { override.returns(Outcome) }
        def availability_sweep
          Balances::Availability.release_due!(@db, clock: @clock)
          Outcome.success
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

        # bin/poller's work, once, at the test clock. New disputes are named after
        # their payment, as the model names them (pi_3's is dp_3).
        sig { void }
        def poll!
          result = Acquirer::NotificationPoller.new(
            db: @db, client: T.must(@deps.acquirer), clock: @clock,
            handlers: Settlement.notification_handlers(clock: @clock)
          ).poll
          raise Clearinghouse::Error, "the acquirer's feed is unavailable: #{result.unavailable}" if result.unavailable

          names = @ids.invert
          @db[:disputes].select_map(%i[id payment_intent]).each do |id, payment|
            name = names[payment]
            @ids[name.sub(/\Api_/, 'dp_')] ||= id if name
          end
        end

        # The simulator's record of the dispute on this payment, nil if it has none.
        sig { params(intent: String).returns(T.nilable(T::Hash[String, T.untyped])) }
        def acquirer_dispute(intent)
          reference = @ids[intent] && @db[:payment_intents].where(id: @ids[intent]).get(:acquirer_reference)
          return nil unless reference

          _, books = acquirer_json(Net::HTTP::Get.new('/admin/operations'))
          books.fetch('disputes').find { |d| d['acquirer_reference'] == reference }
        end

        # A request to the simulator's own endpoints, with the test clock as Sim-Time.
        sig { params(request: Net::HTTPRequest).returns([Integer, T::Hash[String, T.untyped]]) }
        def acquirer_json(request)
          uri = URI.parse(@acquirer_url)
          request['Sim-Time'] = @clock.now.utc.iso8601(6)
          response = Net::HTTP.start(T.must(uri.host), uri.port) { |http| http.request(request) }
          [Integer(response.code), JSON.parse(response.body.to_s)]
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
