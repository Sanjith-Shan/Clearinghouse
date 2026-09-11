# typed: true
# frozen_string_literal: true

require 'json'
require_relative '../../lib/clearinghouse'
require_relative 'isolation/strategies'
require_relative 'isolation/schema'
require_relative 'isolation/runner'

module Experiments
  # Experiment 3, the isolation level shootout: concurrent partial refunds of one
  # payment, plus payouts and disputes against the same merchant balance, run
  # under READ COMMITTED read-then-write, READ COMMITTED with SELECT ... FOR
  # UPDATE, and SERIALIZABLE with retry. Anomalies are counted from the data
  # afterwards (Audit). See docs/design/isolation.md for the results and the
  # decision they led to.
  module Isolation
    extend T::Sig

    MACHINE = 'Apple M3 Pro, 12 cores, 18 GB'
    ANOMALIES = %w[over_refunds over_refunded_cents lost_updates payout_double_spends balance_drift_cents].freeze

    # Pools the trials of one strategy at one thread count.
    sig { params(trials: T::Array[T::Hash[String, T.untyped]]).returns(T::Hash[String, T.untyped]) }
    def self.aggregate(trials)
      first = T.must(trials.first)
      latencies = trials.flat_map { |t| t.fetch('latencies_ms') }.sort
      completed = trials.sum { |t| t.fetch('completed') }
      throughputs = trials.map { |t| t.fetch('ops_per_s') }
      attempts = trials.sum { |t| t.fetch('completed') + t.fetch('exhausted') }
      {
        'strategy' => first.fetch('strategy'), 'threads' => first.fetch('threads'), 'trials' => trials.length,
        'ops_per_s_mean' => (throughputs.sum / throughputs.length).round(1),
        'ops_per_s_min' => throughputs.min, 'ops_per_s_max' => throughputs.max,
        'p50_ms' => percentile(latencies, 0.50), 'p99_ms' => percentile(latencies, 0.99),
        'retries_per_100_ops' => (100.0 * trials.sum { |t| t.fetch('retries') } / attempts).round(2),
        'exhausted' => trials.sum { |t| t.fetch('exhausted') }, 'completed' => completed,
        'trials_with_anomalies' => trials.count { |t| t.fetch('anomalies').values.any?(&:nonzero?) },
        'anomalies' => anomaly_totals(trials)
      }
    end

    sig { params(trials: T::Array[T::Hash[String, T.untyped]]).returns(T::Hash[String, Integer]) }
    def self.anomaly_totals(trials)
      ANOMALIES.to_h { |k| [k, trials.sum { |t| t.fetch('anomalies').fetch(k) }] }
    end

    # Nearest-rank percentile of a sorted list.
    sig { params(sorted: T::Array[Float], quantile: Float).returns(Float) }
    def self.percentile(sorted, quantile)
      return 0.0 if sorted.empty?

      Float(T.must(sorted[[(quantile * sorted.length).ceil - 1, 0].max]).round(2))
    end

    HEADER = [
      '| strategy | threads | trials | ops/s mean (min-max) | p50 ms | p99 ms | retries /100 ops | exhausted | ' \
      'trials with anomalies | over-refunds (cents) | lost updates | payout double-spends | balance drift cents |',
      '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
    ].freeze

    sig { params(rows: T::Array[T::Hash[String, T.untyped]]).returns(String) }
    def self.table(rows)
      lines = rows.map do |r|
        a = r.fetch('anomalies')
        "| #{r['strategy']} | #{r['threads']} | #{r['trials']} | " \
          "#{r['ops_per_s_mean']} (#{r['ops_per_s_min']}-#{r['ops_per_s_max']}) | #{r['p50_ms']} | #{r['p99_ms']} | " \
          "#{r['retries_per_100_ops']} | #{r['exhausted']} | #{r['trials_with_anomalies']}/#{r['trials']} | " \
          "#{a['over_refunds']} (#{a['over_refunded_cents']}) | #{a['lost_updates']} | " \
          "#{a['payout_double_spends']} | #{a['balance_drift_cents']} |"
      end
      (HEADER + lines).join("\n")
    end
  end
end
