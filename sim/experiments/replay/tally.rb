# typed: true
# frozen_string_literal: true

module Experiments
  # Experiment 8's replay (sim/experiments/replay.rb): the arithmetic.
  module Replay
    extend T::Sig

    # What happened to one row. Kept in memory for the run and reduced to aggregates;
    # never written out.
    class Record < T::Struct
      const :fraud, T::Boolean
      const :amount, Integer
      # approved | review | risk_unavailable | unchecked | blocked | declined | error
      const :outcome, String
      const :intent_id, T.nilable(String)
      # The error code for blocked, declined and error, e.g. payment_blocked.
      const :code, T.nilable(String)
      # The confirm call as the client saw it, retries included.
      const :confirm_ms, T.nilable(Float)
      # The risk step inside that confirm, measured around Risk::Client#assess.
      const :risk_ms, T.nilable(Float)
      const :attempts, Integer, default: 1
      const :ruleset_version, T.nilable(String)
    end

    # A dispute that opened on one of the run's payments.
    class Dispute < T::Struct
      const :intent_id, String
      const :amount, Integer
    end

    # Outcomes where the payment went through and money moved.
    SUCCEEDED = %w[approved review risk_unavailable unchecked].freeze
    OUTCOMES = (SUCCEEDED + %w[blocked declined error]).freeze
    # The per-dispute fee is an assumption, not a measurement: Stripe's published US
    # dispute fee, 15.00 USD. Every report labels it as assumed.
    DISPUTE_FEE_CENTS = 1_500

    # The money side of a run, in USD cents. `saved` is what blocking fraud avoided:
    # each blocked fraud payment would otherwise have been captured with the disputing
    # card and disputed for its full amount plus the fee. `cost` is the legitimate
    # revenue blocked, counted at its full amount, the same accounting RiskGate used to
    # choose its thresholds. Reviews change neither: a reviewed payment is captured, so
    # a fraudulent one is still disputed; the hold only keeps the money on the
    # platform until then.
    sig do
      params(records: T::Array[Record], disputes: T::Array[Dispute], fee_cents: Integer)
        .returns(T::Hash[String, T.untyped])
    end
    def self.money(records, disputes:, fee_cents: DISPUTE_FEE_CENTS)
      by_outcome = records.group_by(&:outcome)
      succeeded = records.select { |r| SUCCEEDED.include?(r.outcome) }
      blocked = by_outcome.fetch('blocked', [])
      fraud_caught, legit_blocked = blocked.partition(&:fraud)
      saved = volume(fraud_caught) + (fraud_caught.length * fee_cents)
      cost = volume(legit_blocked)
      {
        'payments' => records.length,
        'fraud_rows' => records.count(&:fraud),
        'outcomes' => OUTCOMES.to_h { |o| [o, by_outcome.fetch(o, []).length] },
        'approved' => bucket(succeeded),
        'blocked' => bucket(blocked),
        'reviews' => bucket(by_outcome.fetch('review', [])),
        'risk_unavailable' => bucket(by_outcome.fetch('risk_unavailable', [])),
        'declined_or_error' => bucket(by_outcome.fetch('declined', []) + by_outcome.fetch('error', [])),
        'fraud_caught' => bucket(fraud_caught),
        'fraud_through' => bucket(succeeded.select(&:fraud)),
        'legit_blocked' => bucket(legit_blocked),
        'disputes' => dispute_counts(records, disputes),
        'dispute_fee_cents_assumed' => fee_cents,
        'dispute_losses_cents' => disputes.sum(&:amount) + (disputes.length * fee_cents),
        'net' => { 'saved_cents' => saved, 'cost_cents' => cost, 'net_cents' => saved - cost }
      }
    end

    # Disputes, and two checks that should both be zero: disputes on rows labelled
    # legitimate, and disputes on payments this run did not make.
    sig { params(records: T::Array[Record], disputes: T::Array[Dispute]).returns(T::Hash[String, Integer]) }
    def self.dispute_counts(records, disputes)
      fraud_by_intent = records.each_with_object({}) { |r, h| h[r.intent_id] = r.fraud if r.intent_id }
      { 'count' => disputes.length, 'volume_cents' => disputes.sum(&:amount),
        'on_legit_rows' => disputes.count { |d| fraud_by_intent[d.intent_id] == false },
        'on_unknown_payments' => disputes.count { |d| !fraud_by_intent.key?(d.intent_id) } }
    end

    sig { params(records: T::Array[Record]).returns(T::Hash[String, Integer]) }
    def self.bucket(records)
      { 'count' => records.length, 'volume_cents' => volume(records) }
    end

    sig { params(records: T::Array[Record]).returns(Integer) }
    def self.volume(records)
      records.sum(&:amount)
    end

    # Confirm latency as the client saw it, and the risk step's part of it.
    sig { params(records: T::Array[Record]).returns(T::Hash[String, T.untyped]) }
    def self.latency(records)
      timed = records.select(&:confirm_ms)
      with_risk = timed.select(&:risk_ms)
      confirm_total = with_risk.sum { |r| T.must(r.confirm_ms) }
      {
        'confirm_ms' => percentiles(timed.map { |r| T.must(r.confirm_ms) }),
        'risk_step_ms' => percentiles(with_risk.map { |r| T.must(r.risk_ms) }),
        # Of the time spent in confirms that called RiskGate, the share spent in the call.
        'risk_share_of_confirm' =>
          (confirm_total.positive? ? (with_risk.sum { |r| T.must(r.risk_ms) } / confirm_total).round(4) : nil),
        'retried_confirms' => timed.count { |r| r.attempts > 1 }
      }
    end

    # Nearest-rank percentiles over the exact samples.
    sig { params(values: T::Array[Float]).returns(T::Hash[String, T.untyped]) }
    def self.percentiles(values)
      return { 'n' => 0 } if values.empty?

      sorted = values.sort
      pick = ->(q) { T.must(sorted[[(q * sorted.length).ceil - 1, 0].max]).round(3) }
      { 'n' => sorted.length, 'p50' => pick.call(0.50), 'p99' => pick.call(0.99), 'p999' => pick.call(0.999),
        'max' => T.must(sorted.last).round(3) }
    end

    # Cents as dollars, "$1,234.56" or "-$12.00".
    sig { params(cents: Integer).returns(String) }
    def self.usd(cents)
      whole, part = cents.abs.divmod(100)
      "#{'-' if cents.negative?}$#{whole.to_s.reverse.scan(/\d{1,3}/).join(',').reverse}.#{format('%02d', part)}"
    end
  end
end
