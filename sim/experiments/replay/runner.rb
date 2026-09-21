# typed: true
# frozen_string_literal: true

require 'json'
require 'net/http'
require_relative '../../../clients/ruby/lib/clearinghouse_client'

module Experiments
  # Experiment 8's replay (sim/experiments/replay.rb): the runner.
  module Replay
    extend T::Sig

    POLICIES = %w[none model_only model_rules].freeze
    # The RiskGate rule file each policy deploys with PUT /v1/rules, relative to
    # RiskGate's checkout.
    RULE_FILES = T.let({ 'model_only' => 'rules/model_only.rules', 'model_rules' => 'rules/default.rules' }.freeze,
                       T::Hash[String, String])
    # What RiskGate's label store reads (internal/service/labels.go).
    WEBHOOK_EVENTS = %w[payment_intent.succeeded charge.dispute.created charge.dispute.closed].freeze
    # A secret RiskGate can be started with before the run (RISKGATE_WEBHOOK_SECRETS),
    # since it reads its secrets only at start. Not a secret: it signs simulated events
    # sent to 127.0.0.1.
    DEFAULT_WEBHOOK_SECRET = 'whsec_exp8_replay_not_a_secret'

    # What the replay loop left for the report.
    class Finished < T::Struct
      const :merchant_id, String
      const :records, T::Array[Record]
      const :first, Row
      const :replay_wall, Float
      const :endpoint_id, T.nilable(String)
      const :drained, T.nilable(T::Boolean)
    end

    # The run's settings.
    class Plan < T::Struct
      const :policy, String
      const :seed, Integer, default: 1
      # Simulated seconds per wall second; 0 replays as fast as the stack answers.
      # Either way the simulated clock is set from each row's `created`.
      const :speed, Float, default: 0.0
      const :dispute_after_days, Integer, default: 7
      const :deadline_ms, Integer, default: 50
      const :webhooks, T::Boolean, default: true
      const :webhook_events, T::Array[String], default: WEBHOOK_EVENTS
      const :webhook_secret, String, default: DEFAULT_WEBHOOK_SECRET
      const :webhook_drain_seconds, Float, default: 120.0
      const :api_threads, Integer, default: 4
      const :webhook_threads, Integer, default: 2
    end

    # PUT the rule file to RiskGate and return the deployed version. A rule set that
    # does not compile stops the run: comparing policies against a stale rule set
    # would be quietly wrong.
    sig { params(url: String, path: String).returns(String) }
    def self.deploy_rules(url, path)
      uri = URI("#{url}/v1/rules")
      request = Net::HTTP::Put.new(uri, 'Content-Type' => 'text/plain')
      request.body = File.read(path)
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 30) { |h| h.request(request) }
      raise "PUT /v1/rules with #{path} failed: #{response.code} #{response.body}" unless response.code == '200'

      JSON.parse(response.body).fetch('version').to_s
    end

    # RiskGate's GET /healthz, or nil when it has none (the fake).
    sig { params(url: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def self.health(url)
      response = Net::HTTP.get_response(URI("#{url}/healthz"))
      response.code == '200' ? JSON.parse(response.body) : nil
    rescue SystemCallError, IOError, JSON::ParserError
      nil
    end

    # Seconds on the monotonic clock.
    sig { returns(Float) }
    def self.monotonic
      Float(Process.clock_gettime(Process::CLOCK_MONOTONIC))
    end

    # 1, 5 and 15 minute load averages.
    sig { returns(T::Array[Float]) }
    def self.load_average
      if File.exist?('/proc/loadavg')
        File.read('/proc/loadavg').split.first(3).map(&:to_f)
      else
        IO.popen(%w[sysctl -n vm.loadavg], &:read).to_s.scan(/[\d.]+/).first(3).map(&:to_f)
      end
    end

    # Replays rows through Clearinghouse: for each, a PaymentIntent with the row's
    # amount, currency and risk_fields, confirmed with automatic capture, at the
    # row's own simulated time. Then simulated time runs past the dispute window and
    # the run is reduced to a report of aggregates.
    class Runner
      extend T::Sig

      sig do
        params(db: Sequel::Database, plan: Plan, riskgate_url: T.nilable(String),
               log: T.nilable(T.any(IO, StringIO))).void
      end
      def initialize(db:, plan:, riskgate_url:, log: $stderr)
        raise ArgumentError, "unknown policy #{plan.policy}" unless POLICIES.include?(plan.policy)
        raise ArgumentError, "policy #{plan.policy} needs a RiskGate URL" if plan.policy != 'none' && !riskgate_url

        @db = db
        @plan = plan
        @riskgate_url = riskgate_url
        @log = log
        @run_name = T.let("exp8-#{SecureRandom.hex(6)}", String)
        @created_skew = T.let(0, Integer)
        @tick_errors = T.let({}, T::Hash[String, Integer])
      end

      # Runs every row and returns the report. `inspect` is called with the stack and
      # the merchant's id before the stack stops, for specs.
      sig do
        params(rows: T::Enumerable[Row],
               inspect: T.nilable(T.proc.params(stack: Stack, merchant_id: String, records: T::Array[Record]).void))
          .returns(T::Hash[String, T.untyped])
      end
      def run(rows, inspect: nil)
        first = rows.first || raise(ArgumentError, 'the replay has no rows')
        check_fresh_feed!
        risk_client = (TimedRiskClient.new(base_url: T.must(@riskgate_url), deadline_ms: @plan.deadline_ms) if
                         @plan.policy != 'none')
        stack = Stack.new(db: @db, start: Time.at(first.created).utc, risk_client: risk_client, seed: @plan.seed,
                          dispute_after_days: @plan.dispute_after_days, api_threads: @plan.api_threads,
                          webhook_threads: @plan.webhook_threads, run_name: @run_name)
        stack.start
        begin
          merchant_id, api = merchant(stack)
          endpoint_id = register_webhook(api) if webhooks?
          stack.start_webhooks if endpoint_id
          started = Replay.monotonic
          records = replay(rows, first, stack, api, risk_client)
          replay_wall = Replay.monotonic - started
          run_past_dispute_window(stack)
          drained = endpoint_id && stack.drain_webhooks(@plan.webhook_drain_seconds, endpoint_id: endpoint_id,
                                                                                     merchant_id: merchant_id)
          finished = Finished.new(merchant_id: merchant_id, records: records, first: first, replay_wall: replay_wall,
                                  endpoint_id: endpoint_id, drained: drained)
          report = build_report(stack, api, finished)
          inspect&.call(stack, merchant_id, records)
          report
        ensure
          stack.stop
        end
      end

      private

      # The scheduler's poller keeps its cursor on the acquirer's feed in the
      # database, but the simulator is new for each run and numbers its feed from
      # the start. A cursor left by an earlier run would skip this run's disputes.
      sig { void }
      def check_fresh_feed!
        return if @db[:acquirer_cursors].exclude(cursor: '0').empty?

        raise ArgumentError, 'the database holds an acquirer feed cursor from an earlier run; use --reset-db'
      end

      sig { returns(T::Boolean) }
      def webhooks?
        @plan.webhooks && @plan.policy != 'none' && !@riskgate_url.nil?
      end

      sig { params(key: String, stack: Stack).returns(ClearinghouseClient::Client) }
      def client(key, stack)
        ClearinghouseClient::Client.new(api_key: key, base_url: stack.api_url, max_network_retries: 3,
                                        read_timeout: 60, rng: Random.new(@plan.seed))
      end

      # A fresh merchant for the run, through the admin endpoint.
      sig { params(stack: Stack).returns([String, ClearinghouseClient::Client]) }
      def merchant(stack)
        admin = client(stack.admin_token, stack)
        created = admin.request(:post, '/v1/merchants', params: { name: "exp8 replay #{@plan.policy}" }).data
        [created.fetch('id'), client(created.fetch('secret_key'), stack)]
      end

      # Registers RiskGate's webhook endpoint and gives it the secret RiskGate was
      # started with. Clearinghouse generates endpoint secrets and shows them once;
      # RiskGate reads its secrets from its environment at start. Setting the row's
      # secret directly (the app role may, as roll_secret does) lets RiskGate be
      # started first. Experiment-only.
      sig { params(api: ClearinghouseClient::Client).returns(String) }
      def register_webhook(api)
        endpoint = api.request(:post, '/v1/webhook_endpoints',
                               params: { url: "#{@riskgate_url}/v1/webhooks/clearinghouse",
                                         enabled_events: @plan.webhook_events,
                                         description: 'RiskGate labels (exp8)' }).data
        id = endpoint.fetch('id')
        @db[:webhook_endpoints].where(id: id).update(secret: @plan.webhook_secret)
        id
      end

      sig do
        params(rows: T::Enumerable[Row], first: Row, stack: Stack, api: ClearinghouseClient::Client,
               risk_client: T.nilable(TimedRiskClient)).returns(T::Array[Record])
      end
      def replay(rows, first, stack, api, risk_client)
        records = []
        day = day_of(stack.clock.now)
        tick(stack)
        wall_start = Replay.monotonic
        rows.each do |row|
          unless row.currency == 'usd'
            raise ArgumentError, "row #{row.index + 1} is in #{row.currency}; the report is in USD"
          end

          pace(row, first, wall_start)
          move_clock(stack, row)
          if day_of(stack.clock.now) != day
            day = day_of(stack.clock.now)
            tick(stack)
          end
          records << pay(api, row, risk_client)
          @log&.puts("#{records.length} rows, #{stack.clock.now.utc.iso8601}") if (records.length % 1000).zero?
        end
        records
      end

      # With a speed, row i waits until (created_i - created_0) / speed wall seconds
      # into the run.
      sig { params(row: Row, first: Row, wall_start: Float).void }
      def pace(row, first, wall_start)
        return unless @plan.speed.positive?

        wait = wall_start + ((row.created - first.created) / @plan.speed) - Replay.monotonic
        sleep(wait) if wait.positive?
      end

      # The clock never goes back, so a row out of order is created at the clock's
      # now, and RiskGate sees that time rather than the row's. Counted in the report.
      sig { params(stack: Stack, row: Row).void }
      def move_clock(stack, row)
        at = Time.at(row.created).utc
        if at >= stack.clock.now
          stack.clock.advance_to(at)
        else
          @created_skew += 1
        end
      end

      sig { params(time: Time).returns(Integer) }
      def day_of(time)
        time.to_i / Clearinghouse::Clock::SECONDS_PER_DAY
      end

      sig { params(stack: Stack).void }
      def tick(stack)
        stack.tick!.errors.each_key { |step| @tick_errors[step] = @tick_errors.fetch(step, 0) + 1 }
      end

      # A day at a time, one tick a day, until every dispute the simulator scheduled
      # has opened: the last capture was at the clock's now, and its dispute opens
      # dispute_after_days later.
      sig { params(stack: Stack).void }
      def run_past_dispute_window(stack)
        (@plan.dispute_after_days + 1).times do
          stack.clock.advance(Clearinghouse::Clock::SECONDS_PER_DAY)
          tick(stack)
        end
        # A final pass at the same simulated time, so a notification that came due
        # during the last tick is applied too.
        tick(stack)
      end

      sig do
        params(api: ClearinghouseClient::Client, row: Row, risk_client: T.nilable(TimedRiskClient)).returns(Record)
      end
      def pay(api, row, risk_client)
        key = "#{@run_name}-#{row.index}"
        intent = api.request(:post, '/v1/payment_intents',
                             params: { amount: row.amount, currency: row.currency, risk_fields: row.risk_fields },
                             idempotency_key: "#{key}-create").data
        id = intent.fetch('id')
        started = Replay.monotonic
        outcome, code, attempts, confirmed = confirm(api, id, row, key)
        elapsed = (Replay.monotonic - started) * 1000.0
        Record.new(fraud: row.fraud, amount: row.amount, outcome: outcome, intent_id: id, code: code,
                   confirm_ms: elapsed, risk_ms: risk_client&.take(id), attempts: attempts,
                   ruleset_version: confirmed&.dig('risk', 'ruleset_version')&.to_s)
      end

      sig do
        params(api: ClearinghouseClient::Client, id: String, row: Row, key: String)
          .returns([String, T.nilable(String), Integer, T.nilable(T::Hash[String, T.untyped])])
      end
      def confirm(api, id, row, key)
        response = api.request(:post, "/v1/payment_intents/#{id}/confirm",
                               params: { payment_method: row.payment_method }, idempotency_key: "#{key}-confirm")
        intent = response.data
        outcome, code = classify(intent)
        [outcome, code, response.attempts, intent]
      rescue ClearinghouseClient::RiskError => e
        [e.code == 'payment_blocked' ? 'blocked' : 'error', e.code, 1, nil]
      rescue ClearinghouseClient::CardError => e
        ['declined', e.decline_code || e.code, 1, nil]
      rescue ClearinghouseClient::Error => e
        ['error', e.code || e.class.name, 1, nil]
      end

      sig { params(intent: T::Hash[String, T.untyped]).returns([String, T.nilable(String)]) }
      def classify(intent)
        return ['error', "status_#{intent['status']}"] unless intent['status'] == 'succeeded'

        case intent.dig('risk', 'decision')
        when nil then ['unchecked', nil]
        when 'allow' then ['approved', nil]
        when 'review' then ['review', nil]
        when Clearinghouse::Risk::Decision::UNAVAILABLE then ['risk_unavailable', intent.dig('risk', 'reason')]
        else ['error', "decision_#{intent.dig('risk', 'decision')}"]
        end
      end

      # Clearinghouse's disputes, opened by the scheduler's notification poller from
      # the acquirer's feed. The simulator's own count is reported beside them.
      sig { params(api: ClearinghouseClient::Client).returns(T::Array[Dispute]) }
      def clearinghouse_disputes(api)
        out = []
        after = T.let(nil, T.nilable(String))
        loop do
          params = { limit: 100 }
          params[:starting_after] = after if after
          page = api.request(:get, '/v1/disputes', params: params).data
          data = page.fetch('data')
          data.each { |d| out << Dispute.new(intent_id: d.fetch('payment_intent'), amount: d.fetch('amount')) }
          break if !page['has_more'] || data.empty?

          after = data.last.fetch('id')
        end
        out
      end

      # Disputes the simulator has opened by the clock's now, on this run's payments.
      sig { params(stack: Stack, records: T::Array[Record]).returns(T::Array[Dispute]) }
      def simulator_disputes(stack, records)
        ours = records.filter_map(&:intent_id).to_set
        by_reference = stack.simulator.authorizations.each_with_object({}) do |auth, h|
          reference = auth.reference
          h[auth.acquirer_reference] = reference if reference && ours.include?(reference)
        end
        now = stack.clock.now
        stack.simulator.disputes.filter_map do |d|
          intent = by_reference[d.acquirer_reference]
          Dispute.new(intent_id: intent, amount: d.amount) if intent && d.opened_at <= now
        end
      end

      sig do
        params(stack: Stack, api: ClearinghouseClient::Client, finished: Finished).returns(T::Hash[String, T.untyped])
      end
      def build_report(stack, api, finished)
        records = finished.records
        replay_wall = finished.replay_wall
        counted = clearinghouse_disputes(api)
        truth = simulator_disputes(stack, records)
        {
          'experiment' => 'exp8-replay',
          'policy' => @plan.policy,
          'plan' => @plan.serialize.except('webhook_secret'),
          'rows' => records.length,
          'simulated' => simulated(stack, finished),
          'replay_wall_seconds' => replay_wall.round(1),
          'rows_per_second' => (records.length / [replay_wall, 0.001].max).round(1),
          'money' => Replay.money(records, disputes: counted),
          'disputes_source' => 'clearinghouse (GET /v1/disputes)',
          'disputes_in_simulator' => { 'count' => truth.length, 'volume_cents' => truth.sum(&:amount) },
          'latency' => Replay.latency(records),
          'riskgate' => riskgate_report(records),
          'error_codes' => records.filter_map { |r| r.code if %w[declined error].include?(r.outcome) }.tally,
          'holds' => holds(finished.merchant_id),
          'balance' => api.request(:get, '/v1/balance').data,
          'webhooks' => webhook_report(stack, finished.endpoint_id, finished.drained),
          'scheduler_step_errors' => @tick_errors,
          'ledger_invariant_violations' => Clearinghouse::Ledger::Invariants.check(@db).length
        }
      end

      sig { params(stack: Stack, finished: Finished).returns(T::Hash[String, T.untyped]) }
      def simulated(stack, finished)
        { 'first_created' => Time.at(finished.first.created).utc.iso8601,
          'clock_at_end' => stack.clock.now.utc.iso8601, 'rows_created_at_a_later_time' => @created_skew }
      end

      sig { params(records: T::Array[Record]).returns(T::Hash[String, T.untyped]) }
      def riskgate_report(records)
        { 'url' => @riskgate_url, 'deadline_ms' => @plan.deadline_ms,
          'ruleset_versions_seen' => records.filter_map(&:ruleset_version).tally.sort.to_h }
      end

      sig { params(merchant_id: String).returns(T::Hash[String, Integer]) }
      def holds(merchant_id)
        rows = @db[:risk_holds].where(merchant_id: merchant_id)
        { 'opened' => rows.count, 'open' => rows.where(closed_at: nil).count,
          'amount_cents' => rows.sum(:amount).to_i, 'held_cents' => rows.sum(:held_amount).to_i }
      end

      sig do
        params(stack: Stack, endpoint_id: T.nilable(String), drained: T.nilable(T::Boolean))
          .returns(T::Hash[String, T.untyped])
      end
      def webhook_report(stack, endpoint_id, drained)
        return { 'registered' => false, 'workers_ran' => false } unless endpoint_id

        deliveries = Sequel[:webhook_deliveries]
        rows = @db[:webhook_deliveries].join(:events, id: :event_id).where(deliveries[:endpoint_id] => endpoint_id)
                                       .group_and_count(Sequel[:events][:type], deliveries[:status]).all
        by_type = rows.each_with_object({}) do |row, h|
          (h[row[:type]] ||= {})[row[:status]] = row[:count]
        end
        { 'registered' => true, 'workers_ran' => stack.webhooks_running?, 'events' => @plan.webhook_events,
          'drained' => drained, 'deliveries' => by_type.sort.to_h }
      end
    end
  end
end
