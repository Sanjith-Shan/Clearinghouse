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

  it 'admits nothing while open, then one probe as half-open' do
    open = fail_times(closed, 3)
    expect(breaker.admit(open, now: now + 29)).to be_nil
    half = breaker.admit(open, now: now + 30)
    expect(half).to have_attributes(state: 'half_open', consecutive_failures: 3, retry_at: nil)
    expect(breaker.in_flight_limit(half, 4)).to eq(1)
    expect(breaker.in_flight_limit(closed, 4)).to eq(4)
    expect(breaker.in_flight_limit(open, 4)).to eq(0)
    expect(breaker.admit(closed, now: now)).to eq(closed)
  end

  it 'reopens after a failed probe with a doubled cool-down, capped' do
    state = fail_times(closed, 3)
    cooldowns = Array.new(5) do
      half = breaker.admit(state, now: state.retry_at)
      state = breaker.after_failure(half, now: half_time = state.retry_at)
      state.retry_at - half_time
    end
    expect(cooldowns).to eq([60.0, 120.0, 200.0, 200.0, 200.0])
    expect(state.reopens).to eq(5)
  end

  it 'closes on a success from any state' do
    expect(breaker.after_success).to eq(closed)
    expect(closed).to have_attributes(state: 'closed', consecutive_failures: 0, reopens: 0, retry_at: nil)
  end
end
