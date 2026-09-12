# typed: true
# frozen_string_literal: true

require 'json'
require 'net/http'
require_relative '../../lib/clearinghouse'
require_relative '../../clients/ruby/lib/clearinghouse_client'

module Experiments
  # Experiment 1, the retry storm (docs/design/storm.md).
  #
  # For each of N PaymentIntents, K clients confirm it at the same moment with the same
  # Idempotency-Key, and each client retries (connection failures, 409, 5xx) with the
  # same key, as ClearinghouseClient does. The acquirer simulator drops a share of its
  # responses after committing, so some confirms end in a truly ambiguous failure.
  # Then it counts, per intent, captured charges from the simulator's own books and
  # capture transactions from the ledger, and byte-compares what the K clients were told.
  #
  # The Runner only needs URLs, so the spec runs it against in-process servers and
  # bin/storm against real processes.
  module Storm
    extend T::Sig

    MACHINE = 'Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker'
    IMPLS = %w[none naive clearinghouse].freeze
    # Where each implementation's confirm lives. The baselines are in
    # lib/clearinghouse/experiments/storm_baselines.rb.
    CONFIRM_PREFIX = T.let({ 'none' => '/experiments/none/v1', 'naive' => '/experiments/naive/v1',
                             'clearinghouse' => '/v1' }.freeze, T::Hash[String, String])
    PAYMENT_METHOD = 'pm_card_visa'

    # The run's shape.
    class Plan < T::Struct
      const :intents, Integer
      const :concurrency, Integer
      const :drop_rate, Float
      const :seed, Integer, default: 1
      # Intents stormed at the same time. Each has its own K clients.
      const :parallel, Integer, default: 4
      # Retries per client call (so up to max_retries + 1 HTTP attempts).
      const :max_retries, Integer, default: 10
      const :amount, Integer, default: 2_000
      # The simulator's latency before it commits, p50 and p99 in ms.
      const :acquirer_latency_ms, [Integer, Integer], default: [0, 0]
    end

    # ClearinghouseClient, unchanged, plus a record of every HTTP attempt it makes:
    # the status (nil when the connection failed) and the last response it got.
    class RecordingClient < ClearinghouseClient::Client
      extend T::Sig

      sig { returns(T::Array[T.nilable(Integer)]) }
      attr_reader :statuses

      sig { returns(T.nilable(ClearinghouseClient::Response)) }
      attr_reader :last

      sig { params(api_key: String, base_url: String, max_network_retries: Integer, rng: Random).void }
      def initialize(api_key:, base_url:, max_network_retries:, rng:)
        super
        @statuses = T.let([], T::Array[T.nilable(Integer)])
        @last = T.let(nil, T.nilable(ClearinghouseClient::Response))
      end

      private

      sig { params(request: Net::HTTPGenericRequest).returns(ClearinghouseClient::Response) }
      def transmit(request)
        response = super
        @statuses << response.status
        @last = response
        response
      rescue ClearinghouseClient::APIConnectionError
        @statuses << nil
        @last = nil
        raise
      end
    end

    # What one client was finally told about its confirm.
    class Answer < T::Struct
      extend T::Sig

      # nil when the last attempt got no response at all.
      const :status, T.nilable(Integer)
      const :body, T.nilable(String)
      const :statuses, T::Array[T.nilable(Integer)]

      # A succeeded PaymentIntent.
      sig { returns(T::Boolean) }
      def paid?
        return false unless status == 200

        JSON.parse(T.must(body))['status'] == 'succeeded'
      rescue JSON::ParserError
        false
      end
    end

    # One implementation's run against the given servers.
    class Runner
      extend T::Sig

      sig do
        params(api_url: String, sim_url: String, db: Sequel::Database, plan: Plan,
               log: T.nilable(T.any(IO, StringIO))).void
      end
      def initialize(api_url:, sim_url:, db:, plan:, log: $stderr)
        @api_url = api_url
        @sim_url = sim_url
        @db = db
        @plan = plan
        @log = log
      end

      sig { params(impl: String).returns(T::Hash[String, T.untyped]) }
      def run(impl)
        raise ArgumentError, "unknown implementation #{impl}" unless IMPLS.include?(impl)

        configure_sim
        secret = merchant_key(impl)
        intents = create_intents(secret)
        @log&.puts("== #{impl}: #{intents.length} intents x #{@plan.concurrency} clients, " \
                   "drop rate #{@plan.drop_rate}")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        answers = storm(impl, secret, intents)
        wall = Float(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        Storm.tally(impl: impl, plan: @plan, intents: intents, answers: answers, wall: wall,
                    acquirer: acquirer_captures, ledger: ledger_captures(intents), rows: intent_rows(intents),
                    violations: Clearinghouse::Ledger::Invariants.check(@db).map(&:serialize))
      end

      private

      # Empty books and the run's misbehaviour, with the same seed for every
      # implementation.
      sig { void }
      def configure_sim
        sim_post('/admin/reset', {})
        p50, p99 = @plan.acquirer_latency_ms
        sim_post('/admin/config', { 'seed' => @plan.seed, 'drop_after_commit_rate' => @plan.drop_rate,
                                    'latency_ms' => { 'p50' => p50, 'p99' => p99 } })
      end

      # A fresh merchant per implementation, so each one's intents are its own.
      sig { params(impl: String).returns(String) }
      def merchant_key(impl)
        _merchant, secret = Clearinghouse::Merchants.create(
          @db, clock: Clearinghouse::Clock::Real.new, name: "storm #{impl}",
               api_version: Clearinghouse::Versioning.latest
        )
        secret
      end

      # Untimed setup, through the real API.
      sig { params(secret: String).returns(T::Array[String]) }
      def create_intents(secret)
        client = ClearinghouseClient::Client.new(api_key: secret, base_url: @api_url, max_network_retries: 5)
        Array.new(@plan.intents) do
          client.request(:post, '/v1/payment_intents',
                         params: { amount: @plan.amount, currency: 'usd' }).data.fetch('id')
        end
      end

      sig do
        params(impl: String, secret: String, intents: T::Array[String]).returns(T::Hash[String, T::Array[Answer]])
      end
      def storm(impl, secret, intents)
        queue = Queue.new
        intents.each_with_index { |id, i| queue << [id, i] }
        queue.close
        answers = T.let({}, T::Hash[String, T::Array[Answer]])
        mutex = Mutex.new
        workers = Array.new([@plan.parallel, intents.length].min) do
          Thread.new do
            while (item = queue.pop)
              id, index = item
              result = storm_one(impl, secret, id, index)
              mutex.synchronize { answers[id] = result }
            end
          end
        end
        workers.each(&:join)
        answers
      end

      # K clients, one key, released together: every client is parked on the gate
      # before any is let go, so all K requests are in flight at once.
      sig { params(impl: String, secret: String, id: String, index: Integer).returns(T::Array[Answer]) }
      def storm_one(impl, secret, id, index)
        key = "storm_#{impl}_#{@plan.seed}_#{index}"
        path = "#{CONFIRM_PREFIX.fetch(impl)}/payment_intents/#{id}/confirm"
        gate = Queue.new
        threads = Array.new(@plan.concurrency) do |j|
          Thread.new do
            client = RecordingClient.new(api_key: secret, base_url: @api_url, max_network_retries: @plan.max_retries,
                                         rng: Random.new((@plan.seed * 1_000_003) + (index * 1_009) + j))
            gate.pop
            confirm(client, path, key)
          end
        end
        Thread.pass until gate.num_waiting == @plan.concurrency
        @plan.concurrency.times { gate << :go }
        threads.map(&:value)
      end

      sig { params(client: RecordingClient, path: String, key: String).returns(Answer) }
      def confirm(client, path, key)
        begin
          client.request(:post, path, params: { payment_method: PAYMENT_METHOD }, idempotency_key: key)
        rescue ClearinghouseClient::Error
          nil # the last attempt's response, if any, is what the client was told
        end
        last = client.last
        Answer.new(status: last&.status, body: last&.body, statuses: client.statuses)
      end

      # Captured authorizations per reference, from the simulator's own books.
      sig { returns(T::Hash[String, Integer]) }
      def acquirer_captures
        books = JSON.parse(sim_get('/admin/operations'))
        books.fetch('charges_by_reference').transform_values { |row| Integer(row.fetch('captured')) }
      end

      sig { params(intents: T::Array[String]).returns(T::Hash[String, Integer]) }
      def ledger_captures(intents)
        @db[:ledger_transactions].where(flow_type: Clearinghouse::Ledger::Flows::PAYMENT, flow_id: intents,
                                        description: 'capture', reverses_transaction_id: nil)
                                 .group_and_count(:flow_id).to_h { |r| [r.fetch(:flow_id), Integer(r.fetch(:count))] }
      end

      sig { params(intents: T::Array[String]).returns(T::Hash[String, [String, Integer]]) }
      def intent_rows(intents)
        @db[:payment_intents].where(id: intents).select(:id, :status, :attempt)
                             .to_h { |r| [r.fetch(:id), [r.fetch(:status), Integer(r.fetch(:attempt))]] }
      end

      sig { params(path: String, body: T::Hash[String, T.untyped]).void }
      def sim_post(path, body)
        uri = URI.join(@sim_url, path)
        response = Net::HTTP.post(uri, JSON.generate(body), 'Content-Type' => 'application/json')
        raise "simulator #{path}: #{response.code} #{response.body}" unless response.code == '200'
      end

      sig { params(path: String).returns(String) }
      def sim_get(path)
        response = Net::HTTP.get_response(URI.join(@sim_url, path))
        raise "simulator #{path}: #{response.code}" unless response.code == '200'

        response.body.to_s
      end
    end

    # Everything the report says about one implementation, from the raw counts.
    sig do
      params(impl: String, plan: Plan, intents: T::Array[String], answers: T::Hash[String, T::Array[Answer]],
             wall: Float, acquirer: T::Hash[String, Integer], ledger: T::Hash[String, Integer],
             rows: T::Hash[String, [String, Integer]], violations: T::Array[T.untyped])
        .returns(T::Hash[String, T.untyped])
    end
    def self.tally(impl:, plan:, intents:, answers:, wall:, acquirer:, ledger:, rows:, violations:)
      charges = intents.to_h { |id| [id, acquirer.fetch(id, 0)] }
      recorded = intents.to_h { |id| [id, ledger.fetch(id, 0)] }
      { 'impl' => impl, 'intents' => intents.length, 'concurrency' => plan.concurrency, 'drop_rate' => plan.drop_rate }
        .merge(money(intents, charges, recorded, rows), told(intents, answers, charges))
        .merge('ledger_invariants' => violations.empty? ? 'hold' : violations, 'wall_seconds' => wall.round(3))
    end

    # Where the money went: the acquirer's captures against the ledger's.
    sig do
      params(intents: T::Array[String], charges: T::Hash[String, Integer], recorded: T::Hash[String, Integer],
             rows: T::Hash[String, [String, Integer]]).returns(T::Hash[String, T.untyped])
    end
    def self.money(intents, charges, recorded, rows)
      {
        'double_charges' => charges.count { |_, n| n > 1 },
        'extra_charges' => charges.values.sum { |n| [n - 1, 0].max },
        'charged_not_recorded' => intents.count { |id| charges.fetch(id) > recorded.fetch(id) },
        'recorded_not_charged' => intents.count { |id| recorded.fetch(id) > charges.fetch(id) },
        'never_charged' => charges.count { |_, n| n.zero? },
        'stuck_processing' => rows.count { |_, (status, _)| status == 'processing' },
        'acquirer_captures_per_intent' => histogram(charges.values),
        'ledger_captures_per_intent' => histogram(recorded.values),
        'confirm_attempts_per_intent' => histogram(rows.values.map(&:last)),
        'final_status' => histogram(rows.values.map(&:first))
      }
    end

    # What the clients were told: the same bytes for every client of an intent, and
    # whether each answer matches what the acquirer did (paid if and only if charged).
    sig do
      params(intents: T::Array[String], answers: T::Hash[String, T::Array[Answer]],
             charges: T::Hash[String, Integer]).returns(T::Hash[String, T.untyped])
    end
    def self.told(intents, answers, charges)
      all = answers.values.flatten
      identical = intents.count do |id|
        bodies = answers.fetch(id).map(&:body)
        bodies.uniq.length == 1 && !bodies.first.nil?
      end
      truthful = intents.sum { |id| answers.fetch(id).count { |a| a.paid? == charges.fetch(id).positive? } }
      {
        'requests' => all.length, 'http_attempts' => all.sum { |a| a.statuses.length },
        'attempts_per_request' => histogram(all.map { |a| a.statuses.length }),
        'answers_by_http_status' => histogram(all.map { |a| a.status || 'no_response' }),
        'identical_body_intents' => identical, 'identical_body_rate' => ratio(identical, intents.length),
        'truthful_answers' => truthful, 'truthful_answer_rate' => ratio(truthful, all.length)
      }
    end

    # Counts by value, integers first in numeric order, keys as strings (JSON's).
    sig { params(values: T::Array[T.untyped]).returns(T::Hash[String, Integer]) }
    def self.histogram(values)
      counts = values.tally
      numbers, others = counts.keys.partition { |k| k.is_a?(Integer) }
      (numbers.sort + others.sort_by(&:to_s)).to_h { |k| [k.to_s, counts.fetch(k)] }
    end

    sig { params(num: Integer, den: Integer).returns(Float) }
    def self.ratio(num, den)
      den.zero? ? 0.0 : Float((num.to_f / den).round(4))
    end

    COLUMNS = [
      ['impl', 'impl'], ['intents', 'intents'], ['K', 'concurrency'], ['drop rate', 'drop_rate'],
      ['requests', 'requests'], ['HTTP attempts', 'http_attempts'], ['double charges', 'double_charges'],
      ['extra charges', 'extra_charges'], ['charged, not in ledger', 'charged_not_recorded'],
      ['stuck processing', 'stuck_processing'], ['ledger captures per intent', 'ledger_captures_per_intent'],
      ['identical bodies', 'identical_body_rate'], ['truthful answers', 'truthful_answer_rate'],
      ['ledger invariants', 'ledger_invariants'], ['wall s', 'wall_seconds']
    ].freeze

    # The report as Markdown: the table, then the run's conditions.
    sig { params(report: T::Hash[String, T.untyped]).returns(String) }
    def self.markdown(report)
      header = "| #{COLUMNS.map(&:first).join(' | ')} |\n|#{COLUMNS.map { '---' }.join('|')}|\n"
      rows = report.fetch('results').map do |r|
        "| #{COLUMNS.map { |_, key| cell(r.fetch(key)) }.join(' | ')} |"
      end
      server = report.fetch('server')
      <<~MD
        # Experiment 1: retry storm (#{report.fetch('label')})

        #{header}#{rows.join("\n")}

        - Command: `#{report.fetch('command')}`
        - Machine: #{report.fetch('machine')}
        - Load (uptime) before: `#{report.fetch('load_before')}`
        - Load (uptime) after: `#{report.fetch('load_after')}`
        - Server: Puma, #{server.fetch('threads')} threads, DB pool #{server.fetch('db_pool')}; baselines on an unknown acquirer answer: #{server.fetch('baseline_on_unknown')}
        - Simulator: drop_after_commit_rate #{report.fetch('plan').fetch('drop_rate')}, seed #{report.fetch('plan').fetch('seed')}, latency p50/p99 #{report.fetch('plan').fetch('acquirer_latency_ms').join('/')} ms
        - Clients: ClearinghouseClient, max #{report.fetch('plan').fetch('max_retries')} retries, #{report.fetch('plan').fetch('parallel')} intents stormed at a time
        - Started #{report.fetch('started_at')}
      MD
    end

    sig { params(value: T.untyped).returns(String) }
    def self.cell(value)
      case value
      when Hash then value.map { |k, v| "#{k}: #{v}" }.join(', ')
      when Float then value.round(4).to_s
      when Array then "#{value.length} violations"
      else value.to_s
      end
    end
  end
end
