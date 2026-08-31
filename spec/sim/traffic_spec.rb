# typed: false
# frozen_string_literal: true

require_relative 'sim_helper'

RSpec.describe AcquirerSim::Traffic do
  def traffic(**config)
    described_class.new(AcquirerSim::Config.new(**config))
  end

  def percentile(sorted, fraction)
    sorted[(fraction * (sorted.size - 1)).round]
  end

  it 'is quiet by default: no latency, no errors, no drops' do
    decisions = Array.new(1_000) { traffic.decide }
    expect(decisions.map(&:latency_seconds).uniq).to eq([0.0])
    expect(decisions.none?(&:unavailable)).to be(true)
    expect(decisions.none?(&:drop_after_commit)).to be(true)
  end

  it 'draws latency from a lognormal whose p50 and p99 match the config' do
    t = traffic(latency_p50_ms: 20.0, latency_p99_ms: 200.0, seed: 7)
    samples = Array.new(40_000) { t.decide.latency_seconds * 1000 }.sort
    expect(percentile(samples, 0.50)).to be_within(1.0).of(20.0)
    expect(percentile(samples, 0.99)).to be_within(20.0).of(200.0)
    expect(samples.first).to be_positive
  end

  it 'answers 503 and drops at roughly the configured rates' do
    t = traffic(error_rate: 0.25, drop_after_commit_rate: 0.1, seed: 3)
    decisions = Array.new(20_000) { t.decide }
    expect(decisions.count(&:unavailable) / 20_000.0).to be_within(0.02).of(0.25)
    expect(decisions.count(&:drop_after_commit) / 20_000.0).to be_within(0.02).of(0.1)
  end

  it 'repeats exactly for the same seed and differs for another' do
    config = { latency_p50_ms: 5.0, latency_p99_ms: 50.0, error_rate: 0.3, drop_after_commit_rate: 0.3 }
    run = lambda do |seed|
      t = traffic(seed: seed, **config)
      Array.new(200) { t.decide.serialize }
    end
    first = run.call(11)
    second = run.call(11)
    expect(second).to eq(first)
    expect(run.call(12)).not_to eq(run.call(11))
  end
end
