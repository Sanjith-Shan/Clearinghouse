# typed: true
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'
require 'socket'
require_relative '../../lib/clearinghouse'

module Experiments
  module Webhooks
    # Experiment 6: webhook delivery under hostile endpoints.
    #
    # One run: a fresh database, 100 endpoints on the hostile server spread over 25
    # merchants, a dispatcher and N worker processes started as real processes
    # (bin/dispatcher, bin/webhook-worker), an open-loop stream of events emitted
    # straight into the outbox, and then a drain until every healthy endpoint has
    # every event or a time limit passes. The hostile server's own log is the ground
    # truth for what arrived and when.
    #
    # Everything runs on the wall clock (Clock::Real in every process), so simulated
    # time and wall time are the same thing here. See results/exp6-webhooks/README.md.
    class Driver
      extend T::Sig

      ROOT = File.expand_path('../..', __dir__)

      # Everything that shapes a run.
      class Settings < T::Struct
        const :database, String, default: 'clearinghouse_exp_webhooks'
        const :endpoints, Integer, default: 100
        const :merchants, Integer, default: 25
        const :error_endpoints, Integer, default: 8
        const :hang_endpoints, Integer, default: 8
        const :flapping_endpoints, Integer, default: 1
        const :rate, Float, default: 25.0
        const :duration, Float, default: 60.0
        const :processes, Integer, default: 4
        const :threads, Integer, default: 8
        const :max_in_flight, Integer, default: 2
        const :breaker_threshold, Integer, default: 5
        const :breaker_cooldown, Float, default: 30.0
        const :connect_timeout, Float, default: 2.0
        const :read_timeout, Float, default: 5.0
        const :total_timeout, Float, default: 10.0
        const :lease, Float, default: 15.0
        const :max_drain, Float, default: 600.0
        const :kill_every, [Float, Float], default: [2.0, 6.0]
        const :seed, Integer, default: 6
        const :raw_dir, String
      end

      # One run's name, queue mode, whether to kill workers, and an optional cap override.
      class Plan < T::Struct
        const :name, String
        const :mode, String
        const :kills, T::Boolean, default: false
        const :max_in_flight, T.nilable(Integer), default: nil
      end

      sig { params(settings: Settings, out: IO).void }
      def initialize(settings, out: $stdout)
        @settings = settings
        @out = out
        @rng = T.let(Random.new(settings.seed), Random)
        @children = T.let([], T::Array[Integer])
        @secrets = T.let({}, T::Hash[Integer, String])
      end

      sig { params(plan: Plan).returns(T::Hash[String, T.untyped]) }
      def run(plan)
        @rng = Random.new(@settings.seed)
        say "== #{plan.name}: #{plan.mode}#{', killing workers' if plan.kills}"
        reset_database!
        db = Clearinghouse::DB.connect(role: :app, database: @settings.database, max_connections: 4)
        port = free_port
        topology = build_topology(db, port)
        log_path = File.join(@settings.raw_dir, "#{plan.name}.server.jsonl")
        File.write(log_path, '')
        processes = [start_server(topology, port, log_path)]
        wait_for_port(port)
        workers = start_workers(plan)
        processes << spawn_child(['bin/dispatcher', '--interval', '0.05'], log: "#{plan.name}.dispatcher.log")
        sleep 3 # let the workers load
        timings = load_and_drain(db, topology, workers, plan)
        stop_children(workers.values + processes)
        summary = analyze(db, topology, log_path, plan).merge(timings)
        db.disconnect
        summary
      ensure
        stop_children(@children.dup)
      end

      # Emits the events (killing workers meanwhile if the plan says so), then waits
      # for the healthy endpoints to have everything.
      sig do
        params(db: Sequel::Database, topology: Topology, workers: T::Hash[Integer, Integer], plan: Plan)
          .returns(T::Hash[String, T.untyped])
      end
      def load_and_drain(db, topology, workers, plan)
        started = monotonic
        killer = plan.kills ? start_killer(workers, plan) : nil
        emitted = generate(db, topology)
        generation_s = monotonic - started
        kills = killer ? stop_killer(killer) : 0
        drained = drain(db, topology, emitted)
        drain_s = monotonic - started - generation_s
        sleep 1 # let the last log lines land
        { 'generation_s' => generation_s.round(1), 'drain_s' => drain_s.round(1), 'drained' => drained,
          'worker_kills' => kills }
      end

      private

      # Endpoint number -> [endpoint id, merchant id, kind], plus the shuffled kinds.
      class Topology < T::Struct
        const :endpoints, T::Hash[Integer, [String, String, String]]
        const :merchants, T::Array[String]
      end

      # Creates the experiment database if it does not exist (never drops one), brings
      # it to the current schema, and empties every table, so each run starts clean.
      sig { void }
      def reset_database!
        admin = Clearinghouse::DB.connect(role: :owner, database: 'postgres', max_connections: 1)
        exists = !admin[:pg_database].where(datname: @settings.database).empty?
        admin.run("CREATE DATABASE #{admin.literal(Sequel.identifier(@settings.database))}") unless exists
        admin.disconnect
        Clearinghouse::DB.migrate!(database: @settings.database)
        owner = Clearinghouse::DB.connect(role: :owner, database: @settings.database, max_connections: 1)
        tables = owner.fetch("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map(:tablename) -
                 %w[schema_migrations]
        owner.transaction do
          # Ledger tables refuse TRUNCATE by trigger; replica mode skips triggers for
          # this transaction only, as the spec helper does.
          owner.run('SET LOCAL session_replication_role = replica')
          names = tables.map { |t| owner.literal(Sequel.identifier(t)) }.join(', ')
          owner.run("TRUNCATE #{names} RESTART IDENTITY CASCADE")
        end
        owner.disconnect
      end

      sig { returns(Integer) }
      def free_port
        probe = TCPServer.new('127.0.0.1', 0)
        port = probe.addr[1]
        probe.close
        port
      end

      sig { params(db: Sequel::Database, port: Integer).returns(Topology) }
      def build_topology(db, port)
        clock = Clearinghouse::Clock::Real.new
        kinds = (%w[error] * @settings.error_endpoints) + (%w[hang] * @settings.hang_endpoints) +
                (%w[flapping] * @settings.flapping_endpoints)
        kinds += %w[healthy] * (@settings.endpoints - kinds.length)
        kinds = kinds.shuffle(random: @rng)
        merchants = Array.new(@settings.merchants) do |i|
          Clearinghouse::Merchants.create(db, clock: clock, name: "exp6 merchant #{i}",
                                              api_version: '2026-09-01').first.id
        end
        @secrets = {}
        endpoints = kinds.each_with_index.to_h do |kind, number|
          endpoint = create_endpoint(db, clock, merchants.fetch(number % merchants.length), port, number)
          @secrets[number] = endpoint.secrets.current
          [number, [endpoint.id, endpoint.merchant_id, kind]]
        end
        Topology.new(endpoints: endpoints, merchants: merchants)
      end

      sig do
        params(db: Sequel::Database, clock: Clearinghouse::Clock, merchant: String, port: Integer, number: Integer)
          .returns(Clearinghouse::Webhooks::Endpoint)
      end
      def create_endpoint(db, clock, merchant, port, number)
        http = Clearinghouse::Webhooks::SafeHttp.new(resolver: Clearinghouse::Webhooks::Egress::SystemResolver.new,
                                                     test_mode: true)
        Clearinghouse::Webhooks::Endpoints.create(
          db, clock: clock, merchant_id: merchant, url: "http://127.0.0.1:#{port}/e/#{number}",
              enabled_events: ['*'], api_version: '2026-09-01', url_check: ->(url) { http.pin(url) }
        )
      end

      sig { params(topology: Topology, port: Integer, log_path: String).returns(Integer) }
      def start_server(topology, port, log_path)
        config = { 'port' => port, 'seed' => @settings.seed,
                   'endpoints' => topology.endpoints.to_h do |number, (_, _, kind)|
                     [number.to_s, { 'kind' => kind, 'secrets' => [@secrets.fetch(number)] }]
                   end }
        config_path = File.join(@settings.raw_dir, 'server-config.json')
        File.write(config_path, JSON.generate(config))
        spawn_child(['exp/webhooks/hostile_server.rb', config_path, log_path], log: 'server.log')
      end

      sig { params(port: Integer).void }
      def wait_for_port(port)
        deadline = monotonic + 20
        begin
          TCPSocket.new('127.0.0.1', port).close
        rescue SystemCallError
          raise "the hostile server did not start; see #{@settings.raw_dir}/server.log" if monotonic > deadline

          sleep 0.1
          retry
        end
      end

      sig { params(plan: Plan).returns(T::Hash[Integer, Integer]) }
      def start_workers(plan)
        Array.new(@settings.processes) { |i| [i, spawn_worker(plan, i)] }.to_h
      end

      sig { params(plan: Plan, index: Integer).returns(Integer) }
      def spawn_worker(plan, index)
        spawn_child(['bin/webhook-worker', '--test-mode', '--mode', plan.mode,
                     '--threads', @settings.threads.to_s,
                     '--max-in-flight', (plan.max_in_flight || @settings.max_in_flight).to_s,
                     '--breaker-threshold', @settings.breaker_threshold.to_s,
                     '--breaker-cooldown', @settings.breaker_cooldown.to_s,
                     '--connect-timeout', @settings.connect_timeout.to_s,
                     '--read-timeout', @settings.read_timeout.to_s,
                     '--total-timeout', @settings.total_timeout.to_s,
                     '--lease', @settings.lease.to_s, '--seed', (@settings.seed + (index * 1000)).to_s],
                    log: "#{plan.name}.worker#{index}.log")
      end

      sig { params(args: T::Array[String], log: String).returns(Integer) }
      def spawn_child(args, log:)
        path = File.join(@settings.raw_dir, log)
        env = { 'CLEARINGHOUSE_DB' => @settings.database }
        pid = T.unsafe(Process).spawn(env, RbConfig.ruby, *args, chdir: ROOT, out: [path, 'a'], err: [path, 'a'])
        @children << pid
        pid
      end

      sig { params(pids: T::Array[Integer]).void }
      def stop_children(pids)
        # Signal them all first, then wait, so they shut down in parallel.
        pids.each { |pid| signal(pid, 'TERM') }
        pids.each { |pid| reap(pid) } # rubocop:disable Style/CombinableLoops
        @children -= pids
      end

      sig { params(pid: Integer).void }
      def reap(pid)
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end

      sig { params(pid: Integer, name: String).void }
      def signal(pid, name)
        Process.kill(name, pid)
      rescue Errno::ESRCH
        nil
      end

      # Open loop: event i is emitted at start + i / rate, however long the last took.
      sig { params(db: Sequel::Database, topology: Topology).returns(Integer) }
      def generate(db, topology)
        clock = Clearinghouse::Clock::Real.new
        intent = JSON.parse(File.read(File.join(ROOT, 'spec/fixtures/resources/payment_intent.json')))
        total = (@settings.rate * @settings.duration).round
        start = monotonic
        total.times do |i|
          delay = start + (i / @settings.rate) - monotonic
          sleep(delay) if delay.positive?
          merchant = topology.merchants.fetch(@rng.rand(topology.merchants.length))
          Clearinghouse::Events.emit!(db, merchant_id: merchant, type: 'payment_intent.succeeded',
                                          object: intent.merge('id' => Clearinghouse::Ids.generate('pi')), clock: clock)
        end
        say "   emitted #{total} events in #{(monotonic - start).round(1)} s"
        total
      end

      # Kills a random worker process with SIGKILL every few seconds and starts a
      # replacement, until stop_killer.
      sig { params(workers: T::Hash[Integer, Integer], plan: Plan).returns(Thread) }
      def start_killer(workers, plan)
        @kill_count = T.let(0, T.nilable(Integer))
        @kill_stop = T.let(false, T.nilable(T::Boolean))
        low, high = @settings.kill_every
        rng = Random.new(@settings.seed + 99)
        Thread.new do
          loop do
            sleep(low + (rng.rand * (high - low)))
            break if @kill_stop

            index = rng.rand(workers.length)
            pid = workers.fetch(index)
            Process.kill('KILL', pid)
            Process.wait(pid)
            @children.delete(pid)
            @kill_count = @kill_count.to_i + 1
            workers[index] = spawn_worker(plan, index)
          end
        end
      end

      sig { params(killer: Thread).returns(Integer) }
      def stop_killer(killer)
        @kill_stop = true
        killer.join
        @kill_count.to_i
      end

      # Waits until every healthy endpoint has recorded success for every event, or
      # max_drain seconds.
      sig { params(db: Sequel::Database, topology: Topology, emitted: Integer).returns(T::Boolean) }
      def drain(db, topology, emitted)
        healthy = topology.endpoints.values.select { |(_, _, kind)| kind == 'healthy' }.map(&:first)
        per_merchant = healthy.group_by { |id| topology.endpoints.values.find { |e| e[0] == id }&.fetch(1) }
                              .transform_values(&:length)
        expected = db[:events].group_and_count(:merchant_id).all
                              .sum { |row| row[:count] * per_merchant.fetch(row[:merchant_id], 0) }
        deadline = monotonic + @settings.max_drain
        loop do
          done = db[:webhook_deliveries].where(endpoint_id: healthy, status: 'succeeded').count
          return true if done >= expected && db[:events].count == emitted
          return false if monotonic > deadline

          sleep 0.5
        end
      end

      sig do
        params(db: Sequel::Database, topology: Topology, log_path: String, plan: Plan)
          .returns(T::Hash[String, T.untyped])
      end
      def analyze(db, topology, log_path, plan)
        Analysis.new(db: db, topology: topology.endpoints, log_path: log_path).summary.merge(
          'run' => plan.name, 'mode' => plan.mode, 'kills' => plan.kills,
          'max_in_flight' => plan.mode == 'fifo' ? nil : (plan.max_in_flight || @settings.max_in_flight)
        )
      end

      sig { params(message: String).void }
      def say(message)
        @out.puts(message)
        @out.flush
      end

      sig { returns(Float) }
      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      end
    end
  end
end
