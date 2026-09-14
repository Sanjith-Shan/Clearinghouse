# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::CircuitBreaker do
  let(:breaker) { described_class.new(failure_threshold: 3, cooldown: 30.0, max_cooldown: 200.0) }
  let(:now) { Time.utc(2026, 9, 1, 12) }
  let(:closed) { described_class::State::CLOSED }

  def fail_times(state, count)
    count.times.reduce(state) { |s, _| breaker.after_failure(s, now: now) }
  end

  it 'stays closed below the threshold and opens at it' do
    two = fail_times(closed, 2)
    expect(two).to have_attributes(state: 'closed', consecutive_failures: 2, retry_at: nil)
    three = breaker.after_failure(two, now: now)
    expect(three).to have_attributes(state: 'open', consecutive_failures: 3, reopens: 0, retry_at: now + 30)
  end

  it 'counts late failures while open without moving the retry time' do
    open = fail_times(closed, 3)
    later = breaker.after_failure(open, now: now + 10)
    expect(later).to have_attributes(state: 'open', consecutive_failures: 4, retry_at: now + 30)
  end

  it 'reopens after a failed probe with a doubled cool-down, capped' do
    state = fail_times(closed, 3)
    cooldowns = Array.new(5) do
      probe_at = state.retry_at
      half = described_class::State.new(state: 'half_open', consecutive_failures: state.consecutive_failures,
                                        reopens: state.reopens, retry_at: nil)
      state = breaker.after_failure(half, now: probe_at)
      state.retry_at - probe_at
    end
    expect(cooldowns).to eq([60.0, 120.0, 200.0, 200.0, 200.0])
    expect(state.reopens).to eq(5)
  end

  it 'closes on a success from any state' do
    expect(breaker.after_success).to eq(closed)
    expect(closed).to have_attributes(state: 'closed', consecutive_failures: 0, reopens: 0, retry_at: nil)
  end
end
