# typed: true
# frozen_string_literal: true

require 'net/http'
require 'rbconfig'
require 'socket'

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): the processes it owns.
  module CrashMatrix
    # A free TCP port on loopback. There is a small window between closing the
    # probe and the child binding it; on one machine running one harness that is
    # good enough, and a collision shows up as a boot failure, not a wrong result.
    sig { returns(Integer) }
    def self.free_port
      server = TCPServer.new('127.0.0.1', 0)
      server.addr[1]
    ensure
      server&.close
    end

    sig { returns(Float) }
    def self.monotonic
      Float(Process.clock_gettime(Process::CLOCK_MONOTONIC))
    end

    # A child process the harness owns: the API, the acquirer simulator or the
    # fake RiskGate. Started in its own process group so a stop takes everything
    # it spawned with it.
    class ChildProcess
      extend T::Sig

      class BootError < StandardError; end

      sig { returns(String) }
      attr_reader :label, :url

      sig { returns(T.nilable(Integer)) }
      attr_reader :pid

      sig do
        params(label: String, argv: T::Array[String], port: Integer, dir: String, env: T::Hash[String, String],
               log: String, health_path: String).void
      end
      def initialize(label:, argv:, port:, dir:, env:, log:, health_path:)
        @label = label
        @argv = argv
        @port = port
        @url = "http://127.0.0.1:#{port}"
        @dir = dir
        @env = env
        @log = log
        @health_path = health_path
        @pid = T.let(nil, T.nilable(Integer))
        @status = T.let(nil, T.nilable(Process::Status))
      end

      # Spawns it and waits until the health path answers 200. Raises if the
      # process exits first or the deadline passes.
      sig { params(timeout: Float).returns(Float) }
      def start(timeout: 60.0)
        started = CrashMatrix.monotonic
        @status = nil
        @pid = T.unsafe(Process).spawn(@env, *@argv, chdir: @dir, out: [@log, 'a'], err: [@log, 'a'],
                                                     pgroup: true, unsetenv_others: false)
        deadline = started + timeout
        until healthy?
          raise BootError, "#{@label} exited with #{exit_status} while booting; see #{@log}" if exited?
          raise BootError, "#{@label} did not come up at #{@url} within #{timeout}s" if CrashMatrix.monotonic > deadline

          sleep 0.05
        end
        CrashMatrix.seconds_since(started)
      end

      sig { returns(T::Boolean) }
      def exited?
        return true if @status
        return true if @pid.nil?

        _, status = Process.waitpid2(@pid, Process::WNOHANG)
        return false unless status

        @status = status
        true
      rescue Errno::ECHILD
        true
      end

      # Blocks until the process exits, for at most `timeout` seconds. nil if it
      # is still running.
      sig { params(timeout: Float).returns(T.nilable(Integer)) }
      def wait_exit(timeout)
        deadline = CrashMatrix.monotonic + timeout
        until exited?
          return nil if CrashMatrix.monotonic > deadline

          sleep 0.02
        end
        exit_status
      end

      # The exit status, or nil if it has not exited (or was killed by a signal).
      sig { returns(T.nilable(Integer)) }
      def exit_status
        @status&.exitstatus
      end

      sig { void }
      def stop
        pid = @pid
        return if pid.nil? || exited?

        Process.kill('TERM', -pid)
        return unless wait_exit(10.0).nil? && !exited?

        Process.kill('KILL', -pid)
        wait_exit(5.0)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      ensure
        @pid = nil if exited?
      end

      private

      sig { returns(T::Boolean) }
      def healthy?
        http = Net::HTTP.new('127.0.0.1', @port)
        http.open_timeout = 0.5
        http.read_timeout = 2
        http.max_retries = 0
        http.get(@health_path).code == '200'
      rescue StandardError
        false
      end
    end

    # The three processes, built the same way every time.
    module Processes
      extend T::Sig

      ROOT = File.expand_path('../../..', __dir__)
      PUMA_THREADS = '1:4'
      # CLEARINGHOUSE_DB_POOL for the API, set explicitly so the report states it.
      DB_POOL = 10

      # The API on Puma, single mode, as `config.ru` builds it from the
      # environment. Launched through `ruby -rbundler/setup` rather than `bundle
      # exec`, which re-execs and costs a second boot on a loaded machine.
      sig { params(port: Integer, env: T::Hash[String, String], log: String).returns(ChildProcess) }
      def self.api(port:, env:, log:)
        argv = [RbConfig.ruby, '-rbundler/setup', Gem.bin_path('puma', 'puma'), '--port', port.to_s,
                '--threads', PUMA_THREADS, '--environment', 'production', '--quiet', 'config.ru']
        ChildProcess.new(label: 'api', argv: argv, port: port, dir: ROOT, env: env, log: log, health_path: '/healthz')
      end

      sig { params(port: Integer, log: String).returns(ChildProcess) }
      def self.sim(port:, log:)
        ChildProcess.new(label: 'sim', argv: [RbConfig.ruby, File.join(ROOT, 'bin/sim'), '--port', port.to_s],
                         port: port, dir: ROOT, env: {}, log: log, health_path: '/health')
      end

      sig { params(port: Integer, log: String).returns(ChildProcess) }
      def self.fake_riskgate(port:, log:)
        ChildProcess.new(label: 'fake-riskgate',
                         argv: [RbConfig.ruby, File.join(ROOT, 'bin/fake-riskgate'), '--port', port.to_s],
                         port: port, dir: ROOT, env: {}, log: log, health_path: '/health')
      end
    end
  end
end
