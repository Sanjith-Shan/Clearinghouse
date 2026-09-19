# typed: true
# frozen_string_literal: true

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): running one case.
  module CrashMatrix
    # One cell of the matrix: a crash name from the registry, and optionally a
    # variant that changes the world around it.
    class Case < T::Struct
      extend T::Sig

      const :flow, String
      const :point, String
      const :moment, Symbol
      # The recovery point committed before `point`, or nil for `started`.
      const :previous, T.nilable(String)
      # nil for a registry point. 'acquirer_drop': the simulator drops the
      # response of every fresh commit once the server has crashed.
      const :variant, T.nilable(String), default: nil

      # Exactly Registry::CrashPoint#to_s: the value for CLEARINGHOUSE_CRASH_AT.
      sig { returns(String) }
      def crash_name
        Clearinghouse::Idempotency::Registry::CrashPoint.new(flow: flow, point: point, moment: moment).to_s
      end

      sig { returns(String) }
      def name = variant ? "#{crash_name}+#{variant}" : crash_name

      sig { returns(T::Boolean) }
      def before_commit? = moment == :before_commit

      # The recovery point the key row must be at right after the crash: this
      # point if the phase committed, the previous one if it rolled back (nil: no
      # row at all, the insert itself rolled back).
      sig { returns(T.nilable(String)) }
      def expected_point_after_crash = before_commit? ? previous : point
    end

    # One named assertion about a case.
    class Check < T::Struct
      const :name, String
      const :ok, T::Boolean
      const :detail, String, default: ''
    end

    # Everything one case produced.
    class CaseResult < T::Struct
      const :kase, Case
      prop :checks, T::Array[Check], default: []
      prop :timings, T::Hash[String, Float], default: {}
      prop :exchanges, T::Hash[String, T::Array[String]], default: {}
      prop :recovery, T::Array[String], default: []
      prop :error, T.nilable(String), default: nil
      # The normalised state at the moment of the crash, and just before the
      # request was sent, for the cross-case before_commit comparison.
      prop :crash_snapshot, T.nilable(T::Hash[String, T.untyped]), default: nil
      prop :baseline_snapshot, T.nilable(T::Hash[String, T.untyped]), default: nil

      extend T::Sig

      sig { returns(T::Boolean) }
      def passed? = error.nil? && checks.all?(&:ok)

      sig { params(name: String, ok: T::Boolean, detail: String).void }
      def check(name, ok, detail = '')
        checks << Check.new(name: name, ok: ok, detail: ok ? detail : "FAILED: #{detail}")
      end
    end

    # How a crashed request is finished.
    #
    # retry: the client resends the same request with the same Idempotency-Key.
    #   While the dead process's lease runs it gets 409 idempotency_key_in_use and
    #   waits; then its request resumes from the recovery point.
    # completer: once the key is the completer's to take (lease expired, and idle
    #   for its grace period), `bin/completer --once` finishes it with no client
    #   involved; the client's retry then gets the stored response as a replay.
    module RecoveryMode
      RETRY = 'retry'
      COMPLETER = 'completer'
      ALL = [RETRY, COMPLETER].freeze
    end

    # Settings shared by every case.
    class Settings < T::Struct
      const :db_name, String
      const :recovery, String, default: RecoveryMode::RETRY
      const :lock_timeout, Float, default: 1.0
      const :completer_command, T::Array[String], default: %w[bin/completer --once]
      const :log_dir, String
    end

    # What one case is working on, handed between its stages.
    class Work < T::Struct
      const :kase, Case
      const :result, CaseResult
      const :scenario, Scenario
      const :merchant_id, String
      # Prefix for every Idempotency-Key the case sends, so keys never repeat.
      const :tag, String
      prop :state, T::Hash[String, String], default: {}
      prop :request, T.nilable(Scenario::Request), default: nil

      extend T::Sig

      # The crashed request's Idempotency-Key; the control's is `control_key`.
      sig { returns(String) }
      def key = "#{tag}:request"

      sig { returns(String) }
      def control_tag = "#{tag}x"

      sig { returns(String) }
      def control_key = "#{control_tag}:request"
    end

    sig { params(started: Float).returns(Float) }
    def self.seconds_since(started)
      (monotonic - started).round(3).to_f
    end

    # Runs cases against real processes: a simulator and a fake RiskGate that
    # live for the whole matrix (reset between cases), and a fresh API process
    # per start.
    class CaseRunner
      extend T::Sig

      API_VERSION = '2026-09-01'
      RETRY_DEADLINE = 30.0
      DROP = 'acquirer_drop'

      sig do
        params(settings: Settings, sim_url: String, proxy: RecordingProxy, riskgate_url: String,
               db: Sequel::Database, owner_db: Sequel::Database).void
      end
      def initialize(settings:, sim_url:, proxy:, riskgate_url:, db:, owner_db:)
        @settings = settings
        @sim = T.let(SimAdmin.new(sim_url), SimAdmin)
        @proxy = proxy
        @riskgate_url = riskgate_url
        @db = db
        @owner_db = owner_db
        @inspector = T.let(Inspector.new(db: db, sim: @sim), Inspector)
        @verifier = T.let(Verifier.new(inspector: @inspector, recovery: settings.recovery), Verifier)
        @clock = T.let(Clearinghouse::Clock::Real.new, Clearinghouse::Clock)
        @server = T.let(nil, T.nilable(ChildProcess))
        @secret = T.let(nil, T.nilable(String))
      end

      # The environment every API process gets. The armed one adds
      # CLEARINGHOUSE_CRASH_AT; nothing else differs.
      sig { returns(T::Hash[String, String]) }
      def base_env
        { 'CLEARINGHOUSE_ENV' => 'experiment', 'RACK_ENV' => 'production', 'CLEARINGHOUSE_DB' => @settings.db_name,
          'CLEARINGHOUSE_ACQUIRER_URL' => @proxy.url, 'RISKGATE_URL' => @riskgate_url,
          # Generous, so a loaded machine cannot turn an allow into a fail-open
          # verdict in one run and not the other.
          'RISKGATE_DEADLINE_MS' => '5000',
          'CLEARINGHOUSE_IDEMPOTENCY_LOCK_TIMEOUT' => @settings.lock_timeout.to_s,
          'CLEARINGHOUSE_DB_POOL' => Processes::DB_POOL.to_s,
          'CLEARINGHOUSE_CRASH_AT' => '' }
      end

      sig { params(kase: Case, index: Integer).returns(CaseResult) }
      def run(kase, index)
        result = CaseResult.new(kase: kase)
        started = CrashMatrix.monotonic
        begin
          work = Work.new(kase: kase, result: result, scenario: CrashMatrix.scenario_for(kase.flow),
                          merchant_id: fresh_world, tag: format('c%<i>03d', i: index))
          crash(work)
          recover_and_verify(work)
        rescue StandardError => e
          result.error = "#{e.class}: #{e.message}"
        ensure
          @server&.stop
          @server = nil
          result.timings['total_s'] = CrashMatrix.seconds_since(started)
        end
        result
      end

      private

      # The armed server: set up, send, and watch it die.
      sig { params(work: Work).void }
      def crash(work)
        result = work.result
        api = start_api(work.kase.crash_name, result, 'boot_armed_s', "#{work.tag}-armed")
        work.state = timed(result, 'setup_s') do
          work.scenario.prepare(@db, work.merchant_id, @clock, work.scenario.setup(api, work.tag))
        end
        raise 'the armed server died during setup' if T.must(@server).exited?

        work.request = work.scenario.request(work.state)
        result.baseline_snapshot = @inspector.snapshot(work.merchant_id, work.key)
        send_and_die(work, api)
        result.crash_snapshot = @inspector.snapshot(work.merchant_id, work.key)
        @verifier.check_crash_state(work)
        @server = nil
      end

      # Sends the request the hook is armed for. The connection must drop and the
      # process must exit with the crash status, not any other way.
      sig { params(work: Work, api: ApiClient).void }
      def send_and_die(work, api)
        request = T.must(work.request)
        mark = @proxy.mark
        sent = CrashMatrix.monotonic
        reply = api.post(request.path, request.params, key: work.key)
        status = T.must(@server).wait_exit(30.0)
        work.result.timings['crash_s'] = CrashMatrix.seconds_since(sent)
        work.result.exchanges['crashed_request'] = @proxy.since(mark).map(&:to_s)
        work.result.check('crashed',
                          reply.dropped? && status == Clearinghouse::Idempotency::CrashHook::CRASH_STATUS,
                          "client saw #{reply}, process exit status #{status.inspect}")
      end

      # A clean server, recovery, a further retry, then the control: the same
      # request uninterrupted under another key, on the same server.
      sig { params(work: Work).void }
      def recover_and_verify(work)
        result = work.result
        request = T.must(work.request)
        @sim.configure('drop_after_commit_rate' => 1.0) if work.kase.variant == DROP
        api = start_api(nil, result, 'boot_clean_s', "#{work.tag}-clean")
        final = timed(result, 'recover_s') { recover(work, api) }
        again = api.post(request.path, request.params, key: work.key)
        @sim.configure('drop_after_commit_rate' => 0.0) if work.kase.variant == DROP

        control_state = work.scenario.prepare(@db, work.merchant_id, @clock, work.scenario.setup(api, work.control_tag))
        control_request = work.scenario.request(control_state)
        control = api.post(control_request.path, control_request.params, key: work.control_key)
        timed(result, 'verify_s') do
          @verifier.verify(work, final: final, again: again, control_state: control_state, control: control)
        end
      end

      # An empty database with one merchant, and an empty simulator. The merchant
      # is written directly: creating one is not what is being tested.
      sig { returns(String) }
      def fresh_world
        CrashMatrix.reset_database!(@owner_db)
        @sim.reset!
        merchant, @secret = Clearinghouse::Merchants.create(@db, clock: @clock, name: 'Crash matrix',
                                                                 api_version: API_VERSION)
        merchant.id
      end

      sig do
        params(crash_at: T.nilable(String), result: CaseResult, timing: String, log_name: String).returns(ApiClient)
      end
      def start_api(crash_at, result, timing, log_name)
        port = CrashMatrix.free_port
        env = base_env.merge('CLEARINGHOUSE_CRASH_AT' => crash_at.to_s)
        server = @server = Processes.api(port: port, env: env, log: File.join(@settings.log_dir, "#{log_name}.log"))
        result.timings[timing] = server.start
        ApiClient.new(url: "http://127.0.0.1:#{port}", secret_key: T.must(@secret))
      end

      sig { params(work: Work, api: ApiClient).returns(Reply) }
      def recover(work, api)
        return retry_until_answered(work, api) unless @settings.recovery == RecoveryMode::COMPLETER

        run_completer(work)
        request = T.must(work.request)
        mark = @proxy.mark
        reply = api.post(request.path, request.params, key: work.key)
        work.result.recovery << "retry after completer: #{reply}#{' (replayed)' if reply.replayed?}"
        work.result.exchanges['client_retry'] = @proxy.since(mark).map(&:to_s)
        reply
      end

      # Resends until the answer is neither "still in use" nor a retryable 503.
      sig { params(work: Work, api: ApiClient).returns(Reply) }
      def retry_until_answered(work, api)
        request = T.must(work.request)
        deadline = CrashMatrix.monotonic + RETRY_DEADLINE
        attempt = 0
        loop do
          attempt += 1
          mark = @proxy.mark
          reply = api.post(request.path, request.params, key: work.key)
          work.result.recovery << "retry #{attempt}: #{reply}#{' (replayed)' if reply.replayed?}"
          work.result.exchanges["retry_#{attempt}"] = @proxy.since(mark).map(&:to_s)
          in_use = reply.status == 409 && reply.error_code == 'idempotency_key_in_use'
          retryable = reply.status == 503 && reply.headers['clearinghouse-should-retry'] == 'true'
          return reply unless (in_use || retryable) && CrashMatrix.monotonic < deadline

          sleep(in_use ? 0.1 : 0.05)
        end
      end

      # Runs the completer until the key is finished (a dropped acquirer answer
      # takes two passes), each pass once the key is the completer's to take.
      sig { params(work: Work).void }
      def run_completer(work)
        3.times do |pass|
          state = @inspector.key_state(work.merchant_id, work.key)
          break if state.nil? || state['recovery_point'] == 'finished'

          wait_until_takeable(work)

          mark = @proxy.mark
          log = File.join(@settings.log_dir, "#{work.tag}-completer-#{pass + 1}.log")
          pid = T.unsafe(Process).spawn(base_env, *@settings.completer_command, chdir: Processes::ROOT,
                                                                                out: [log, 'a'], err: [log, 'a'])
          _, status = Process.wait2(pid)
          after = @inspector.key_state(work.merchant_id, work.key)
          work.result.recovery << "completer pass #{pass + 1}: exit #{T.must(status).exitstatus}, key at " \
                                  "#{after && after['recovery_point']}"
          work.result.exchanges["completer_#{pass + 1}"] = @proxy.since(mark).map(&:to_s)
        end
      end

      # Idempotency::Completer#candidates: no live lease, and no run for at
      # least the grace period, which bin/completer defaults to the lock timeout.
      sig { params(work: Work).void }
      def wait_until_takeable(work)
        deadline = CrashMatrix.monotonic + RETRY_DEADLINE
        loop do
          locked, last_run = @inspector.lease_times(work.merchant_id, work.key)
          cutoff = @clock.now - @settings.lock_timeout
          return if (locked.nil? || locked <= cutoff) && (last_run.nil? || last_run <= cutoff)
          raise "#{work.key} did not become the completer's to take" if CrashMatrix.monotonic > deadline

          sleep 0.05
        end
      end

      sig do
        type_parameters(:R).params(result: CaseResult, name: String, blk: T.proc.returns(T.type_parameter(:R)))
                           .returns(T.type_parameter(:R))
      end
      def timed(result, name, &blk)
        started = CrashMatrix.monotonic
        value = blk.call
        result.timings[name] = CrashMatrix.seconds_since(started)
        value
      end
    end
  end
end
