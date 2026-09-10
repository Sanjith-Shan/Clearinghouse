# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Risk::CircuitBreaker do
  subject(:breaker) do
    described_class.new(clock: clock, consecutive: 3, failure_rate: 0.5, window: 10.0, min_calls: 10, cooldown: 2.0,
                        on_transition: ->(t) { transitions << t })
  end

  let(:clock) { Clearinghouse::Risk::Monotonic::Manual.new }
  let(:transitions) { [] }
  let(:state) { described_class::State }

  def call!(success)
    permit = breaker.acquire
    raise 'no permit' unless permit

    breaker.record(permit, success: success)
  end

  it 'starts closed and hands out ordinary permits' do
    expect(breaker.state).to eq(state::Closed)
    expect(breaker.acquire).to have_attributes(probe: false)
  end

  it 'opens after the configured run of consecutive failures, and not before' do
    2.times { call!(false) }
    expect(breaker.state).to eq(state::Closed)
    call!(false)
    expect(breaker.state).to eq(state::Open)
    expect(transitions.last).to have_attributes(from: state::Closed, to: state::Open, why: '3 consecutive failures')
  end

  it 'resets the run on a success' do
    2.times { call!(false) }
    call!(true)
    2.times { call!(false) }
    expect(breaker.state).to eq(state::Closed)
  end

  it 'refuses every call while open, without limit' do
    3.times { call!(false) }
    expect(Array.new(100) { breaker.acquire }).to all(be_nil)
  end

  it 'opens on a failure rate over the window once enough calls were seen' do
    # F S F S F S F S F never makes a run of 3, and 9 calls are under min_calls.
    9.times { |i| call!(i.odd?) }
    expect(breaker.state).to eq(state::Closed)
    call!(false) # 6 failures in 10 calls
    expect(breaker.state).to eq(state::Open)
    expect(transitions.last.why).to eq('failure rate 0.60 over 10s')
  end

  it 'forgets failures older than the window' do
    9.times { |i| call!(i.odd?) } # F S F S F S F S F: 5 of 9 failed, under min_calls
    clock.advance(11.0)
    # Counted together with the old ones this would be 6 of 10 and open the breaker.
    call!(false)
    expect(breaker.state).to eq(state::Closed)
  end

  describe 'half-open' do
    before { 3.times { call!(false) } }

    it 'stays open until the cool-down has passed on the monotonic clock' do
      clock.advance(1.99)
      expect(breaker.acquire).to be_nil
      clock.advance(0.01)
      expect(breaker.state).to eq(state::HalfOpen)
    end

    it 'lets exactly one probe through, even with many callers' do
      clock.advance(2.0)
      permits = Array.new(8) { Thread.new { breaker.acquire } }.map(&:value)
      expect(permits.compact.length).to eq(1)
      expect(permits.compact.first.probe).to be(true)
    end

    it 'closes with clean statistics when the probe succeeds' do
      clock.advance(2.0)
      breaker.record(breaker.acquire, success: true)
      expect(breaker.state).to eq(state::Closed)
      2.times { call!(false) } # the old run of 3 does not carry over
      expect(breaker.state).to eq(state::Closed)
      expect(transitions.map(&:to)).to eq([state::Open, state::HalfOpen, state::Closed])
    end

    it 'reopens for a full cool-down when the probe fails' do
      clock.advance(2.0)
      breaker.record(breaker.acquire, success: false)
      expect(breaker.state).to eq(state::Open)
      clock.advance(1.5)
      expect(breaker.acquire).to be_nil
      clock.advance(0.5)
      expect(breaker.acquire).to have_attributes(probe: true)
    end
  end

  it 'ignores results from permits issued before a transition' do
    slow = breaker.acquire
    3.times { call!(false) }
    clock.advance(2.0)
    probe = breaker.acquire
    # The slow call that started while closed finally returns a success. It must not
    # close the breaker: only the probe decides.
    breaker.record(slow, success: true)
    expect(breaker.state).to eq(state::HalfOpen)
    breaker.record(probe, success: false)
    expect(breaker.state).to eq(state::Open)
  end

  it 'rejects nonsense parameters' do
    expect { described_class.new(consecutive: 0) }.to raise_error(ArgumentError)
    expect { described_class.new(failure_rate: 1.5) }.to raise_error(ArgumentError)
    expect { described_class.new(cooldown: 0.0) }.to raise_error(ArgumentError)
  end
end
