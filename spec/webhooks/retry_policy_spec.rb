# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::RetryPolicy do
  let(:policy) { described_class.new }
  let(:start) { Time.utc(2026, 9, 1, 12) }

  # Every attempt time for a delivery that always fails, starting at `start`.
  def schedule(seed)
    rng = Random.new(seed)
    deadline = policy.deadline_for(start)
    times = [start]
    while (next_at = policy.next_attempt_at(times.length, now: times.last, deadline: deadline, rng: rng))
      times << next_at
    end
    times
  end

  it 'draws each delay uniformly below min(cap, base * 2^(n-1))' do
    rng = Random.new(7)
    expect(policy.delay(1, Random.new(7))).to eq(Random.new(7).rand * 60.0)
    1000.times do
      n = rng.rand(1..40)
      ceiling = [12 * 3600.0, 60.0 * (2**(n - 1))].min
      expect(policy.delay(n, rng)).to be >= 0.0
      expect(policy.delay(n, rng)).to be < ceiling
    end
  end

  it 'reaches the 12 hour cap at the eleventh attempt and stays there' do
    maxed = Array.new(2000) { policy.delay(11, Random.new(_1)) }.max
    expect(maxed).to be_between(11.9 * 3600, 12 * 3600)
    expect(Array.new(2000) { policy.delay(500, Random.new(_1)) }.max).to be < 12 * 3600
  end

  it 'is deterministic for a seed' do
    first = schedule(42)
    again = schedule(42)
    expect(again).to eq(first)
    expect(schedule(43)).not_to eq(first)
  end

  it 'keeps every attempt inside the 3 day window and gives up on the next one' do
    counts = (1..500).map do |seed|
      times = schedule(seed)
      expect(times.last).to be <= start + (3 * 86_400)
      times.length
    end
    # Measured over 2000 seeds while writing this: min 16, median 21, max 30.
    expect(counts.min).to be >= 12
    expect(counts.max).to be <= 35
    expect(counts.sum.fdiv(counts.length)).to be_between(19, 24)
  end

  it 'spreads the retries of deliveries that failed together' do
    firsts = (1..200).map { |seed| schedule(seed)[1] }
    expect(firsts.uniq.length).to eq(200)
    expect(firsts.max - firsts.min).to be > 50
  end

  it 'refuses attempt numbers below 1' do
    expect { policy.delay(0, Random.new(1)) }.to raise_error(ArgumentError)
  end

  describe 'against a real endpoint that always fails', :db do
    let(:clock) { Clearinghouse::Clock::Test.new(start: start) }
    let(:server) { LocalHttpServer.new { |socket, _| LocalHttpServer.respond(socket, 503) } }

    after { server.stop }

    it 'follows the same schedule and then marks the delivery failed' do
      merchant = Clearinghouse::Merchants.create(app_db, clock: clock, name: 'M', api_version: '2026-09-01').first
      WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id,
                                                 url: "http://127.0.0.1:#{server.port}/")
      event_id = WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id)
      WebhookSpecHelpers.dispatcher(app_db, clock: clock).run_once
      worker = WebhookSpecHelpers.worker(app_db, clock: clock, seed: 42)

      attempted_at = []
      loop do
        attempted_at << clock.now
        break if worker.work_once.state == :failed

        clock.advance_to(WebhookSpecHelpers.delivery(app_db, event_id)[:next_attempt_at])
      end
      # Postgres keeps microseconds, so compare to the millisecond.
      expected = schedule(42)
      expect(attempted_at.length).to eq(expected.length)
      attempted_at.zip(expected).each { |at, want| expect(at).to be_within(0.001).of(want) }
      expect(server.requests.length).to eq(attempted_at.length)
      expect(WebhookSpecHelpers.delivery(app_db, event_id))
        .to include(status: 'failed', attempts: attempted_at.length, last_error: 'http_503')
    end
  end
end
