# typed: true
# frozen_string_literal: true

require 'json'

module Clearinghouse
  module Webhooks
    # N delivery threads in one process, each running its own Worker against a shared
    # connection pool. Threads are fine here: a worker spends nearly all its time
    # waiting on a socket or on Postgres, and Ruby releases the GVL for both.
    #
    # Nothing in a pool coordinates with any other pool. Every guarantee (no double
    # claim, the per-endpoint cap, the breaker) lives in Postgres, so running four
    # processes of eight threads is the same as one of thirty-two, and killing one
    # process loses only the deliveries it had leased, until their leases expire.
    class WorkerPool
      extend T::Sig

      WorkerFactory = T.type_alias { T.proc.params(index: Integer).returns(Worker) }

      sig do
        params(threads: Integer, idle_sleep: Float, log: T.nilable(T.any(IO, StringIO)),
               factory: WorkerFactory).void
      end
      def initialize(threads:, idle_sleep: 0.05, log: nil, &factory)
        @workers = T.let(Array.new(threads) { |index| factory.call(index) }, T::Array[Worker])
        @idle_sleep = idle_sleep
        @log = log
        @stopping = T.let(false, T::Boolean)
        @threads = T.let([], T::Array[Thread])
      end

      # Starts the threads and returns at once.
      sig { returns(T.self_type) }
      def start
        @threads = @workers.map { |worker| Thread.new(worker) { |w| run_worker(w) } }
        self
      end

      # Asks every thread to stop after its current delivery, and waits for them.
      sig { void }
      def stop
        @stopping = true
        @threads.each(&:join)
      end

      sig { void }
      def wait
        @threads.each(&:join)
      end

      private

      sig { params(worker: Worker).void }
      def run_worker(worker)
        until @stopping
          begin
            sleep(@idle_sleep) unless worker.work_once
          rescue StandardError => e
            # The database went away or a query failed. Whatever this worker had
            # leased stays leased until the lease expires, then someone retries it.
            @log&.puts(JSON.generate({ 'worker' => worker.name, 'level' => 'error', 'exception' => e.class.name,
                                       'message' => e.message }))
            sleep(@idle_sleep * 10)
          end
        end
      end
    end
  end
end
