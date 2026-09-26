# typed: true
# frozen_string_literal: true

module Experiments
  module Isolation
    # One trial's settings. The mix is refund-heavy on purpose: every refund goes
    # to the one "hot" payment until it is used up, so `threads` refunds are
    # fighting over one row most of the time.
    class Plan < T::Struct
      const :threads, Integer
      const :ops, Integer
      const :seed, Integer
      const :captured, Integer, default: 10_000
      const :refund_amount, Integer, default: 1_000
      const :dispute_amount, Integer, default: 1_500
      const :credit_amount, Integer, default: 5_000
      const :opening_balance, Integer, default: 50_000
      const :mix, T::Hash[Symbol, Float], default: { refund: 0.7, dispute: 0.1, payout: 0.1, credit: 0.1 }
    end

    # Runs one trial: `plan.threads` threads, each holding its own connection from
    # a pool of that size, share `plan.ops` operations, then Audit reads what
    # happened.
    class Runner
      extend T::Sig

      BALANCE_QUEUE = "balance:#{Operations::MERCHANT}".freeze

      sig { params(db: Sequel::Database, strategy: Strategies::Strategy, plan: Plan).void }
      def initialize(db:, strategy:, plan:)
        @db = db
        @strategy = strategy
        @plan = plan
        @mutex = Mutex.new
        @next_op = 0
        @hot = 1
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def run
        Schema.reset!(@db, payments: @plan.ops + 1, captured: @plan.captured, available: @plan.opening_balance)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stats = Array.new(@plan.threads) { |i| Thread.new { worker(Random.new((@plan.seed * 1_000) + i)) } }
                     .map(&:value)
        elapsed = Float(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        summarize(stats, elapsed).merge('anomalies' => Audit.run(@db))
      end

      private

      sig { params(random: Random).returns(T::Hash[Symbol, T.untyped]) }
      def worker(random)
        stats = { latencies: [], applied: 0, declined: 0, exhausted: 0, retries: 0 }
        # Hold one connection for the whole trial, like a request worker would.
        @db.synchronize do
          while take_op
            began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            begin
              result, attempts = one_op(random)
              stats[result] += 1
              stats[:retries] += attempts - 1
            rescue Strategies::RetriesExhausted => e
              stats[:exhausted] += 1
              stats[:retries] += e.attempts - 1
            end
            stats[:latencies] << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - began)
          end
        end
        stats
      end

      sig { returns(T::Boolean) }
      def take_op
        @mutex.synchronize do
          return false if @next_op >= @plan.ops

          @next_op += 1
          true
        end
      end

      sig { params(random: Random).returns([Symbol, Integer]) }
      def one_op(random)
        case pick(random)
        when :refund
          payment = @mutex.synchronize { @hot }
          # Queue names as production's: refunds of one payment queue on its intent
          # (Payments::Flows.intent_queue), payouts on the balance (Payouts::Flows).
          result, attempts = @strategy.run(@db, queue: "payment_intent:#{payment}") do |txn|
            Operations.refund(txn, payment, @plan.refund_amount)
          end
          # Used up: move every thread on to the next payment.
          @mutex.synchronize { @hot = payment + 1 if @hot == payment } if result == :declined
          [result, attempts]
        when :dispute then @strategy.run(@db) { |txn| Operations.dispute(txn, @plan.dispute_amount) }
        when :payout then @strategy.run(@db, queue: BALANCE_QUEUE) { |txn| Operations.payout(txn) }
        else @strategy.run(@db) { |txn| Operations.credit(txn, @plan.credit_amount) }
        end
      end

      sig { params(random: Random).returns(Symbol) }
      def pick(random)
        roll = random.rand
        @plan.mix.each do |kind, share|
          return kind if roll < share

          roll -= share
        end
        :credit
      end

      sig { params(stats: T::Array[T::Hash[Symbol, T.untyped]], elapsed: Float).returns(T::Hash[String, T.untyped]) }
      def summarize(stats, elapsed)
        latencies = stats.flat_map { |s| s[:latencies] }.map { |l| (l * 1000).round(3) }.sort
        done = stats.sum { |s| s[:applied] + s[:declined] }
        {
          'strategy' => @strategy.name, 'threads' => @plan.threads, 'seed' => @plan.seed, 'ops' => @plan.ops,
          'elapsed_s' => elapsed.round(3), 'completed' => done,
          'applied' => stats.sum { |s| s[:applied] }, 'declined' => stats.sum { |s| s[:declined] },
          'retries' => stats.sum { |s| s[:retries] }, 'exhausted' => stats.sum { |s| s[:exhausted] },
          'ops_per_s' => (done / elapsed).round(1),
          'p50_ms' => Isolation.percentile(latencies, 0.50), 'p99_ms' => Isolation.percentile(latencies, 0.99),
          'latencies_ms' => latencies
        }
      end
    end
  end
end
