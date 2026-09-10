# typed: true
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'rbconfig'
require_relative '../../lib/clearinghouse'

module Experiments
  # Experiment 9 at the client level: a steady stream of risk steps through
  # Risk::Client while the RiskGate process is killed (or frozen) and brought
  # back. It measures what failing open costs (payments that went through
  # unchecked) and whether the step's latency stays bounded by the deadline while
  # it happens. The end-to-end version through confirm needs the payments area.
  #
  # Open loop: call i is due at start + i / rate whatever happened to earlier
  # calls, and its latency is measured from that due time, so a stall shows up as
  # queueing in the numbers instead of as calls that were never sent
  # (coordinated omission).
  module RiskFailure
    extend T::Sig

    MACHINE = 'Apple M3 Pro, 12 cores, 18 GB'
    FAKE_SCRIPT = File.expand_path('../../bin/fake-riskgate', __dir__)

    # A RiskGate process the experiment owns, so it can kill and restart it.
    class Target
      extend T::Sig

      sig { returns(String) }
      attr_reader :label, :url

      sig { params(label: String, url: String, argv: T::Array[String], dir: String, env: T::Hash[String, String]).void }
      def initialize(label:, url:, argv:, dir:, env: {})
        @label = label
        @url = url
        @argv = argv
        @dir = dir
        @env = env
        @pid = T.let(nil, T.nilable(Integer))
      end

      sig { params(timeout: Float).void }
      def start(timeout: 30.0)
        @pid = T.unsafe(Process).spawn(@env, *@argv, chdir: @dir, out: File::NULL, err: File::NULL, pgroup: true)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until up?
          raise "#{@label} did not come up at #{@url}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
      end

      # Starts it without waiting for it to answer: the run keeps going while it boots.
      sig { void }
      def start_async
        @pid = T.unsafe(Process).spawn(@env, *@argv, chdir: @dir, out: File::NULL, err: File::NULL, pgroup: true)
      end

      sig { params(signal: String).void }
      def signal(signal)
        Process.kill(signal, T.must(@pid))
      end

      sig { void }
      def kill
        signal('KILL')
        Process.wait(T.must(@pid))
        @pid = nil
      end

      sig { void }
      def stop
        return unless @pid

        Process.kill('CONT', @pid)
        Process.kill('KILL', @pid)
        Process.wait(@pid)
        @pid = nil
      rescue Errno::ESRCH, Errno::ECHILD
        @pid = nil
      end

      sig { returns(T::Boolean) }
      def up?
        uri = URI(@url)
        Net::HTTP.start(uri.host, uri.port, open_timeout: 0.2, read_timeout: 0.5) do |http|
          http.post('/v1/assess', '{}', 'Content-Type' => 'application/json')
        end
        true
      rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout
        false
      end
    end

    # One step's measurement.
    class Sample < T::Struct
      const :due, Float           # seconds since the run started
      const :latency_ms, Float    # from the due time: includes waiting for a worker
      const :service_ms, Float    # the step itself
      const :phase, String
      const :decision, String     # allow | review | block | risk_unavailable
      const :reason, T.nilable(String)
    end

    # The run's shape. Durations in seconds.
    class Plan < T::Struct
      const :rate, Float
      const :healthy, Float
      const :down, Float
      const :after, Float
      const :mode, String # kill | freeze
      const :deadline_ms, Integer
      const :workers, Integer
    end

    # The report as a Markdown section.
    sig { params(report: T::Hash[String, T.untyped]).returns(String) }
    def self.summary(report)
      plan = report.fetch('plan')
      timeline = report.fetch('timeline')
      lines = ["## #{report['target']}, #{plan['mode']}", '',
               "#{report['calls']} calls at #{plan['rate']}/s, deadline #{plan['deadline_ms']} ms. " \
               "**#{report['unchecked']} went through unchecked** (#{report['unchecked_by_reason']}).", '',
               "Fault at #{timeline['fault_at']}s, restart at #{timeline['restart_at']}s, first checked payment " \
               "after restart at #{timeline['first_checked_after_restart'].inspect}s.", '']
      if (load = report['load_average'])
        lines << "Load average (1/5/15 min) before #{load['before'].join('/')}, after #{load['after'].join('/')}." << ''
      end
      lines.concat(phase_table(report))
      lines << '' << 'Breaker transitions:' << ''
      report.fetch('breaker_transitions').each { |t| lines << "- #{t['t']}s #{t['from']} -> #{t['to']} (#{t['why']})" }
      lines.join("\n")
    end

    sig { params(report: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def self.phase_table(report)
      rows = ['| phase | calls | unchecked | p50 ms | p99 ms | p99.9 ms | max ms | service p99 ms |',
              '|---|---|---|---|---|---|---|---|']
      report.fetch('phases').merge('overall' => report.fetch('overall')).each do |phase, s|
        next rows << "| #{phase} | 0 | | | | | | |" if s['calls'].zero?

        l = s['latency_ms']
        rows << "| #{phase} | #{s['calls']} | #{s['unchecked']} | #{l['p50']} | #{l['p99']} | #{l['p999']} | " \
                "#{l['max']} | #{s['service_ms']['p99']} |"
      end
      rows
    end

    PHASES = %w[healthy down_breaker_closed breaker_open recovering healthy_after].freeze

    # Runs the plan against the target and returns the report as a Hash.
    class Runner
      extend T::Sig

      sig do
        params(target: Target, plan: Plan, requests: T.proc.params(i: Integer).returns(Clearinghouse::Risk::AssessRequest),
               log: T.nilable(IO)).void
      end
      def initialize(target:, plan:, requests:, log: $stderr)
        @target = target
        @plan = plan
        @requests = requests
        @log = log
        @transitions = T.let([], T::Array[T::Hash[String, T.untyped]])
        @mutex = Mutex.new
        @t0 = T.let(0.0, Float)
        @fault_at = T.let(Float::INFINITY, Float)
        @restart_at = T.let(Float::INFINITY, Float)
        @recovered_at = T.let(Float::INFINITY, Float)
        breaker = Clearinghouse::Risk::CircuitBreaker.new(on_transition: ->(t) { record_transition(t) })
        @client = T.let(Clearinghouse::Risk::Client.new(base_url: target.url, deadline_ms: plan.deadline_ms,
                                                        breaker: breaker), Clearinghouse::Risk::Client)
        @clock = T.let(Clearinghouse::Clock::Test.new, Clearinghouse::Clock::Test)
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def run
        total = @plan.healthy + @plan.down + @plan.after
        count = (total * @plan.rate).floor
        queue = Queue.new
        samples = T.let([], T::Array[Sample])
        workers = Array.new(@plan.workers) { Thread.new { work(queue, samples) } }
        @t0 = now
        faults = Thread.new { drive_faults }
        count.times do |i|
          due = i / @plan.rate
          wait = @t0 + due - now
          sleep(wait) if wait.positive?
          queue << [i, due]
        end
        workers.size.times { queue << nil }
        workers.each(&:join)
        faults.join
        @client.close
        report(samples, count)
      end

      private

      sig { returns(Float) }
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      end

      sig { void }
      def drive_faults
        sleep_until(@plan.healthy)
        @fault_at = now - @t0
        if @plan.mode == 'freeze'
          @target.signal('STOP')
          note("froze #{@target.label} (SIGSTOP)")
        else
          @target.kill
          note("killed #{@target.label} (SIGKILL)")
        end
        sleep_until(@plan.healthy + @plan.down)
        @restart_at = now - @t0
        if @plan.mode == 'freeze'
          @target.signal('CONT')
          note("thawed #{@target.label} (SIGCONT)")
        else
          @target.start_async
          note("restarted #{@target.label}")
        end
      end

      sig { params(offset: Float).void }
      def sleep_until(offset)
        wait = @t0 + offset - now
        sleep(wait) if wait.positive?
      end

      sig { params(queue: Queue, samples: T::Array[Sample]).void }
      def work(queue, samples)
        while (job = queue.pop)
          i, due = job
          phase = phase_at(now - @t0)
          started = now
          outcome = Clearinghouse::Risk::Step.call(intent(i), attempt: 1, clock: @clock, client: @client)
          finished = now
          risk = outcome.verdict.risk
          if outcome.verdict.checked? && finished - @t0 > @restart_at
            @mutex.synchronize { @recovered_at = [@recovered_at, finished - @t0].min }
          end
          sample = Sample.new(due: due, latency_ms: (finished - @t0 - due) * 1000,
                              service_ms: (finished - started) * 1000, phase: phase,
                              decision: risk.fetch('decision'), reason: risk['reason'])
          @mutex.synchronize { samples << sample }
        end
      end

      sig { params(seq: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def intent(seq)
        request = @requests.call(seq)
        { id: request.payment_id, amount: request.amount.amount, currency: request.amount.currency,
          created_at: Time.at(request.created).utc, risk_fields: request.risk_fields }
      end

      # The phase a call belongs to, from the fault timeline and the breaker's state
      # when the call started. A call that starts just before the fault lands in
      # healthy even if the fault cuts it off.
      sig { params(offset: Float).returns(String) }
      def phase_at(offset)
        return 'healthy' if offset < @fault_at
        if offset >= @restart_at
          return @mutex.synchronize { offset < @recovered_at } ? 'recovering' : 'healthy_after'
        end

        closed = @client.breaker.state == Clearinghouse::Risk::CircuitBreaker::State::Closed
        closed ? 'down_breaker_closed' : 'breaker_open'
      end

      sig { params(transition: Clearinghouse::Risk::CircuitBreaker::Transition).void }
      def record_transition(transition)
        @transitions << { 't' => (now - @t0).round(3), 'from' => transition.from.serialize,
                          'to' => transition.to.serialize, 'why' => transition.why }
      end

      sig { params(message: String).void }
      def note(message)
        @log&.puts(format('%<t>7.3fs  %<m>s', t: now - @t0, m: message))
      end

      sig { params(samples: T::Array[Sample], count: Integer).returns(T::Hash[String, T.untyped]) }
      def report(samples, count)
        unchecked = samples.count { |s| s.decision == Clearinghouse::Risk::Decision::UNAVAILABLE }
        {
          'experiment' => 'exp9-risk-failure (client level)',
          'machine' => MACHINE,
          'ruby' => RUBY_DESCRIPTION,
          'target' => @target.label,
          'plan' => @plan.serialize,
          'calls' => count,
          'completed' => samples.length,
          'unchecked' => unchecked,
          'unchecked_by_reason' => tally(samples.filter_map(&:reason)),
          'decisions' => tally(samples.map(&:decision)),
          'timeline' => { 'fault_at' => @fault_at.round(3), 'restart_at' => @restart_at.round(3),
                          'first_checked_after_restart' => @recovered_at.finite? ? @recovered_at.round(3) : nil },
          'breaker_transitions' => @transitions,
          'phases' => PHASES.to_h { |p| [p, phase_stats(samples.select { |s| s.phase == p })] },
          'overall' => phase_stats(samples),
          'per_second' => per_second(samples)
        }
      end

      sig { params(values: T::Array[String]).returns(T::Hash[String, Integer]) }
      def tally(values)
        values.tally.sort.to_h
      end

      sig { params(samples: T::Array[Sample]).returns(T::Hash[String, T.untyped]) }
      def phase_stats(samples)
        return { 'calls' => 0 } if samples.empty?

        {
          'calls' => samples.length,
          'unchecked' => samples.count { |s| s.decision == Clearinghouse::Risk::Decision::UNAVAILABLE },
          'reasons' => tally(samples.filter_map(&:reason)),
          'latency_ms' => percentiles(samples.map(&:latency_ms)),
          'service_ms' => percentiles(samples.map(&:service_ms))
        }
      end

      sig { params(samples: T::Array[Sample]).returns(T::Array[T::Hash[String, T.untyped]]) }
      def per_second(samples)
        samples.group_by { |s| s.due.floor }.sort.map do |second, group|
          { 's' => second, 'calls' => group.length,
            'unchecked' => group.count { |s| s.decision == Clearinghouse::Risk::Decision::UNAVAILABLE },
            'p99_ms' => percentiles(group.map(&:latency_ms)).fetch('p99') }
        end
      end

      # Nearest-rank percentiles over the exact samples; runs are small enough that
      # a histogram would only add error.
      sig { params(values: T::Array[Float]).returns(T::Hash[String, Float]) }
      def percentiles(values)
        sorted = values.sort
        pick = ->(q) { T.must(sorted[[(q * sorted.length).ceil - 1, 0].max]).round(3) }
        { 'p50' => pick.call(0.50), 'p99' => pick.call(0.99), 'p999' => pick.call(0.999),
          'max' => T.must(sorted.last).round(3) }
      end
    end
  end
end
