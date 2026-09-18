# typed: true
# frozen_string_literal: true

require 'net/http'
require 'puma'
require 'puma/server'
require 'securerandom'
require_relative '../../../lib/clearinghouse'
require_relative '../../lib/acquirer_sim'

module Experiments
  # Experiment 8's replay (sim/experiments/replay.rb): the in-process stack.
  module Replay
    extend T::Sig

    # Risk::Client, plus the wall time of each assess call by payment id, so the
    # report can say how much of a confirm was the risk step. The replay owns the
    # server's dependencies, which is why it can measure inside the confirm.
    class TimedRiskClient < Clearinghouse::Risk::Client
      extend T::Sig

      sig do
        params(base_url: String, deadline_ms: Integer).void
      end
      def initialize(base_url:, deadline_ms:)
        super
        @timings = T.let({}, T::Hash[String, Float])
        @timings_mutex = T.let(Mutex.new, Thread::Mutex)
      end

      sig { params(request: Clearinghouse::Risk::AssessRequest, attempt: Integer).returns(Clearinghouse::Risk::Result) }
      def assess(request, attempt:)
        started = Replay.monotonic
        result = super
        elapsed = (Replay.monotonic - started) * 1000.0
        @timings_mutex.synchronize { @timings[request.payment_id] = elapsed }
        result
      end

      # The step's time for this payment, forgotten once read.
      sig { params(payment_id: String).returns(T.nilable(Float)) }
      def take(payment_id)
        @timings_mutex.synchronize { @timings.delete(payment_id) }
      end
    end

    # Everything a replay runs against, in this process: the acquirer simulator and
    # the API on Puma over real sockets, sharing one test clock that the replay moves;
    # the scheduler, ticked by the replay at each simulated day; and the webhook
    # dispatcher and delivery workers on the wall clock, because RiskGate checks
    # signature timestamps against its own wall clock.
    class Stack
      extend T::Sig

      sig { returns(Clearinghouse::Clock::Test) }
      attr_reader :clock

      sig { returns(AcquirerSim::Simulator) }
      attr_reader :simulator

      sig { returns(Clearinghouse::Api::Dependencies) }
      attr_reader :deps

      sig { returns(String) }
      attr_reader :admin_token

      sig do
        params(db: Sequel::Database, start: Time, risk_client: T.nilable(Clearinghouse::Risk::Client),
               seed: Integer, dispute_after_days: Integer, api_threads: Integer, webhook_threads: Integer,
               run_name: String).void
      end
      def initialize(db:, start:, risk_client:, seed:, dispute_after_days:, api_threads: 4, webhook_threads: 2,
                     run_name: "exp8-#{SecureRandom.hex(4)}")
        @db = db
        @clock = T.let(Clearinghouse::Clock::Test.new(start: start), Clearinghouse::Clock::Test)
        @seed = seed
        @dispute_after_days = dispute_after_days
        @api_threads = api_threads
        @webhook_threads = webhook_threads
        @run_name = run_name
        @admin_token = T.let("adm_#{SecureRandom.hex(16)}", String)
        @simulator = T.let(AcquirerSim::Simulator.new, AcquirerSim::Simulator)
        @sim_server = T.let(puma(AcquirerSim::App.new(simulator: @simulator), 16), Puma::Server)
        acquirer = Clearinghouse::Acquirer::Client.new(clock: @clock, base_url: sim_url)
        @deps = T.let(Clearinghouse::Api::Dependencies.new(
                        db: db, clock: @clock, acquirer: acquirer, risk_client: risk_client,
                        admin_token: @admin_token,
                        webhook_http: Clearinghouse::Webhooks::SafeHttp.new(
                          resolver: Clearinghouse::Webhooks::Egress::SystemResolver.new, test_mode: true
                        )
                      ), Clearinghouse::Api::Dependencies)
        @api_server = T.let(nil, T.nilable(Puma::Server))
        @scheduler = T.let(Clearinghouse::Scheduler.new(@deps),
                           Clearinghouse::Scheduler)
        @webhook_threads_running = T.let([], T::Array[Thread])
        @webhook_pool = T.let(nil, T.nilable(Clearinghouse::Webhooks::WorkerPool))
        @stopping = T.let(false, T::Boolean)
      end

      sig { returns(T.self_type) }
      def start
        configure_sim
        @api_server = puma(Clearinghouse::Api.rack_app(@deps), @api_threads)
        self
      end

      sig { returns(String) }
      def api_url
        "http://127.0.0.1:#{T.must(@api_server).connected_ports.first}"
      end

      sig { returns(String) }
      def sim_url
        "http://127.0.0.1:#{@sim_server.connected_ports.first}"
      end

      # One scheduler pass at the simulated now: expiry, the acquirer's notification
      # feed (disputes, payouts), settlement files, availability, payouts, the
      # completer and the reaper.
      sig { returns(Clearinghouse::Scheduler::TickReport) }
      def tick!
        @scheduler.tick!(@clock)
      end

      # The webhook dispatcher and delivery workers, on the wall clock.
      sig { void }
      def start_webhooks
        real = Clearinghouse::Clock::Real.new
        dispatcher = Clearinghouse::Webhooks::Dispatcher.new(db: @db, clock: real, name: @run_name)
        @webhook_threads_running << Thread.new do
          until @stopping
            begin
              sleep(0.05) if dispatcher.run_once.scanned.zero?
            rescue Sequel::Error => e
              warn "exp8 dispatcher: #{e.class}: #{e.message}"
              sleep(0.5)
            end
          end
        end
        http = Clearinghouse::Webhooks::SafeHttp.new(resolver: Clearinghouse::Webhooks::Egress::SystemResolver.new,
                                                     test_mode: true)
        @webhook_pool = Clearinghouse::Webhooks::WorkerPool.new(threads: @webhook_threads) do |index|
          Clearinghouse::Webhooks::Worker.new(db: @db, clock: real, http: http, rng: Random.new(@seed + index),
                                              name: "#{@run_name}-#{index}")
        end.start
      end

      sig { returns(T::Boolean) }
      def webhooks_running?
        !@webhook_pool.nil?
      end

      # Waits until every event of the merchant's has been fanned out and no delivery
      # to the endpoint is pending, up to `timeout` seconds of wall time. Returns
      # whether it drained.
      sig { params(timeout: Float, endpoint_id: String, merchant_id: String).returns(T::Boolean) }
      def drain_webhooks(timeout, endpoint_id:, merchant_id:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          return true if undispatched_events(merchant_id).zero? && pending_deliveries(endpoint_id).zero?
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep(0.2)
        end
      end

      sig { void }
      def stop
        @stopping = true
        @webhook_pool&.stop
        @webhook_threads_running.each(&:join)
        @api_server&.stop(true)
        @sim_server.stop(true)
        @deps.risk_client&.close
      end

      private

      sig { params(app: T.untyped, threads: Integer).returns(Puma::Server) }
      def puma(app, threads)
        server = Puma::Server.new(app, nil, min_threads: 1, max_threads: threads, log_writer: Puma::LogWriter.null)
        server.add_tcp_listener('127.0.0.1', 0)
        server.run
        server
      end

      sig { void }
      def configure_sim
        response = Net::HTTP.post(URI("#{sim_url}/admin/config"),
                                  JSON.generate('seed' => @seed, 'dispute_after_days' => @dispute_after_days),
                                  'Content-Type' => 'application/json')
        raise "simulator refused its config: #{response.body}" unless response.code == '200'
      end

      sig { params(endpoint_id: String).returns(Integer) }
      def pending_deliveries(endpoint_id)
        @db[:webhook_deliveries].where(endpoint_id: endpoint_id, status: 'pending').count
      end

      # The merchant's events above this run's dispatch cursor.
      sig { params(merchant_id: String).returns(Integer) }
      def undispatched_events(merchant_id)
        cursor = @db[:webhook_dispatch_cursors].where(name: @run_name).get(:cursor_seq).to_i
        @db[:events].where(merchant_id: merchant_id).where(Sequel.lit('seq > ?', cursor)).count
      end
    end
  end
end
