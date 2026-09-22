# typed: true
# frozen_string_literal: true

require 'fileutils'
require 'json'

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): one whole run.
  module CrashMatrix
    # One run of the matrix: starts the simulator, the fake RiskGate and the
    # recording proxy once, runs every case, and writes the report. Used by
    # bin/crash-matrix and by the spec that runs a few cases end to end.
    class Session
      extend T::Sig

      sig { returns(T::Array[CaseResult]) }
      attr_reader :results

      sig do
        params(settings: Settings, cases: T::Array[Case], full: T::Boolean,
               progress: T.nilable(T.proc.params(line: String).void)).void
      end
      def initialize(settings:, cases:, full:, progress: nil)
        @settings = settings
        @cases = cases
        @full = full
        @progress = progress
        @results = T.let([], T::Array[CaseResult])
      end

      sig { params(command: String).returns(T::Hash[String, T.untyped]) }
      def run(command:)
        FileUtils.mkdir_p(@settings.log_dir)
        load_before = CrashMatrix.load_average
        started_at = Clearinghouse::Clock::Real.new.now
        started = CrashMatrix.monotonic
        with_world do |runner, background|
          @cases.each_with_index do |kase, i|
            result = (kase.background ? background : runner).run(kase, i + 1)
            @results << result
            @progress&.call(format('%<i>3d/%<n>d %<r>-4s %<t>6.1fs %<name>s%<err>s',
                                   i: i + 1, n: @cases.length, r: result.passed? ? 'ok' : 'FAIL',
                                   t: result.timings['total_s'], name: kase.name,
                                   err: result.passed? ? '' : "  #{failure_line(result)}"))
          end
        end
        CrashMatrix.compare_rollbacks(@results)
        CrashMatrix.report(@results, meta(command, started_at, started, load_before))
      end

      private

      sig { params(blk: T.proc.params(runner: CaseRunner, background: BackgroundRunner).void).void }
      def with_world(&blk)
        sim = Processes.sim(port: CrashMatrix.free_port, log: File.join(@settings.log_dir, 'sim.log'))
        risk = Processes.fake_riskgate(port: CrashMatrix.free_port, log: File.join(@settings.log_dir, 'riskgate.log'))
        sim.start
        risk.start
        proxy = RecordingProxy.new(upstream_port: Integer(sim.url[/\d+\z/])).start
        db = Clearinghouse::DB.connect(role: :app, database: @settings.db_name, max_connections: 4)
        owner = Clearinghouse::DB.connect(role: :owner, database: @settings.db_name, max_connections: 1)
        Clearinghouse::DB.migrate!(database: @settings.db_name)
        begin
          world = { settings: @settings, sim_url: sim.url, proxy: proxy, riskgate_url: risk.url, db: db,
                    owner_db: owner }
          blk.call(CaseRunner.new(**world), BackgroundRunner.new(**world))
        ensure
          db.disconnect
          owner.disconnect
          proxy.stop
          risk.stop
          sim.stop
        end
      end

      # The commit the run's code came from, marked dirty if the tree had changes.
      sig { returns(String) }
      def git_describe
        sha = IO.popen(%w[git rev-parse --short HEAD], chdir: Processes::ROOT, &:read).to_s.strip
        dirty = !IO.popen(%w[git status --porcelain --untracked-files=no], chdir: Processes::ROOT, &:read).to_s.empty?
        dirty ? "#{sha}-dirty" : sha
      end

      sig { params(result: CaseResult).returns(String) }
      def failure_line(result)
        return T.must(result.error) if result.error

        result.checks.reject(&:ok).map { |c| "#{c.name}: #{c.detail[0, 200]}" }.join(' | ')
      end

      sig do
        params(command: String, started_at: Time, started: Float,
               load_before: T::Array[Float]).returns(T::Hash[String, T.untyped])
      end
      def meta(command, started_at, started, load_before)
        registry = Clearinghouse::Payments::Flows.registry
        background = Clearinghouse::Settlement.background_crash_points
        db = Clearinghouse::DB.connect(role: :app, database: @settings.db_name, max_connections: 1)
        postgres = db.fetch('SHOW server_version').single_value
        db.disconnect
        { 'experiment' => 'exp2-crash-matrix', 'command' => command, 'machine' => MACHINE, 'git' => git_describe,
          'postgres' => "PostgreSQL #{postgres}", 'recovery_mode' => @settings.recovery,
          'api_process' => { 'puma_threads' => Processes::PUMA_THREADS, 'db_pool' => Processes::DB_POOL },
          'lock_timeout_s' => @settings.lock_timeout, 'database' => @settings.db_name,
          'started_at' => started_at.iso8601, 'duration_s' => (CrashMatrix.monotonic - started).round(1),
          'load_average' => { 'before' => load_before, 'after' => CrashMatrix.load_average },
          'full_matrix' => @full, 'registry_flows' => registry.flows.map(&:name),
          'flows_without_scenario' => CrashMatrix.flows_without_scenario(registry),
          'registry_crash_points' => registry.crash_points.length,
          'background_flows' => background.map(&:flow).uniq, 'background_crash_points' => background.length }
      end
    end
  end
end
