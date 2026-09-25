# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::IsolatedQueue, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { Clearinghouse::Merchants.create(app_db, clock: clock, name: 'M', api_version: '2026-09-01').first }
  let(:breaker) { Clearinghouse::Webhooks::CircuitBreaker.new(failure_threshold: 3, cooldown: 30.0) }
  let(:queue) { described_class.new(max_in_flight: 2, breaker: breaker) }

  def endpoint(path)
    WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id,
                                               url: "https://hooks.example.com/#{path}")
  end

  # `count` events, each delivered to every endpoint that exists at the time.
  def backlog(count)
    Array.new(count) { WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id) }
    WebhookSpecHelpers.dispatcher(app_db, clock: clock).run_until_idle
  end

  def claim(from = queue, db: app_db, token: 't')
    from.claim(db, now: clock.now, lease_seconds: 60, token: token)
  end

  def endpoint_row(hook)
    app_db[:webhook_endpoints].where(id: hook.id).first
  end

  def live_leases(hook)
    app_db[:webhook_deliveries].where(endpoint_id: hook.id, status: 'pending').exclude(lease_token: nil)
                               .where(Sequel.lit('lease_expires_at > ?', clock.now)).count
  end

  describe 'the in-flight cap' do
    it 'must allow at least one delivery in flight, or nothing would ever be sent' do
      expect { described_class.new(max_in_flight: 0) }
        .to raise_error(ArgumentError, 'max_in_flight must be at least 1')
    end

    it 'leases at most max_in_flight deliveries per endpoint and moves on to the next endpoint' do
      a = endpoint('a')
      clock.advance(1)
      backlog(10)
      clock.advance(1)
      b = endpoint('b')
      clock.advance(1)
      backlog(1)

      claims = Array.new(4) { claim }
      expect(claims.compact.map(&:endpoint_id)).to eq([a.id, a.id, b.id])
      expect(claims.last).to be_nil
      expect(live_leases(a)).to eq(2)
    end

    it 'holds across two worker instances on separate connections hammering the same endpoint' do
      hook = endpoint('a')
      backlog(50)
      second_db = Clearinghouse::DB.connect(role: :app, max_connections: 8)
      begin
        queues = [described_class.new(max_in_flight: 3, breaker: breaker),
                  described_class.new(max_in_flight: 3, breaker: breaker)]
        dbs = [app_db, second_db]
        start = Thread::Queue.new
        threads = Array.new(12) do |i|
          Thread.new do
            start.pop
            Array.new(20) { claim(queues[i % 2], db: dbs[i % 2], token: "w#{i}") }.compact
          end
        end
        12.times { start << true }
        claimed = threads.flat_map(&:value)
        expect(claimed.length).to eq(3)
        expect(live_leases(hook)).to eq(3)
      ensure
        second_db.disconnect
      end
    end

    it 'frees a slot when a delivery is recorded, and when a dead worker lease expires' do
      hook = endpoint('a')
      backlog(5)
      first = claim
      claim
      expect(claim).to be_nil

      # Record a success for the first by hand (no network in this spec).
      app_db[:webhook_deliveries].where(id: first.delivery_id)
                                 .update(status: 'succeeded', succeeded_at: clock.now, lease_token: nil,
                                         lease_expires_at: nil)
      expect(claim&.endpoint_id).to eq(hook.id)
      expect(claim).to be_nil

      clock.advance(60)
      expect(Array.new(3) { claim }.compact.length).to eq(2)
    end

    it 'skips an endpoint whose row another claimer holds, instead of waiting' do
      a = endpoint('a')
      clock.advance(1)
      backlog(1)
      clock.advance(1)
      b = endpoint('b')
      backlog(1)
      holding_row_lock(a) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect(claim.endpoint_id).to eq(b.id)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      end
      expect(claim.endpoint_id).to eq(a.id)
    end

    # Holds hook's row lock from another connection while the block runs.
    def holding_row_lock(hook)
      other_db = Clearinghouse::DB.connect(role: :app, max_connections: 1)
      locked = Thread::Queue.new
      release = Thread::Queue.new
      holder = Thread.new do
        other_db.transaction do
          other_db[:webhook_endpoints].where(id: hook.id).for_update.first
          locked << true
          release.pop
        end
      end
      locked.pop
      yield
    ensure
      release << true
      holder.join
      other_db.disconnect
    end
  end

  describe 'the circuit breaker' do
    let(:open_until) { clock.now + 30 }

    def trip(hook)
      app_db[:webhook_endpoints].where(id: hook.id)
                                .update(breaker_state: 'open', consecutive_failures: 3, breaker_retry_at: open_until)
    end

    it 'claims nothing for an open endpoint and serves the others' do
      a = endpoint('a')
      clock.advance(1)
      backlog(3)
      clock.advance(1)
      b = endpoint('b')
      backlog(1)
      trip(a)
      expect(claim.endpoint_id).to eq(b.id)
      expect(claim).to be_nil
      expect(app_db[:webhook_deliveries].where(endpoint_id: a.id).select_map(:attempts)).to all(eq(0))
    end

    it 'goes half-open after the cool-down and admits exactly one probe' do
      a = endpoint('a')
      backlog(5)
      trip(a)
      clock.advance_to(open_until)
      probe = claim
      expect(probe.endpoint_id).to eq(a.id)
      expect(endpoint_row(a)[:breaker_state]).to eq('half_open')
      expect(claim).to be_nil
    end

    it 'closes when the probe succeeds and reopens for longer when it fails' do
      a = endpoint('a')
      backlog(5)
      trip(a)
      clock.advance_to(open_until)
      claim
      Clearinghouse::Webhooks::Breakers.failure(app_db, a.id, breaker, now: clock.now)
      expect(endpoint_row(a)).to include(breaker_state: 'open', breaker_reopens: 1,
                                         breaker_retry_at: clock.now + 60)

      Clearinghouse::Webhooks::Breakers.success(app_db, a.id)
      expect(endpoint_row(a)).to include(breaker_state: 'closed', consecutive_failures: 0, breaker_reopens: 0,
                                         breaker_retry_at: nil)
      app_db[:webhook_deliveries].update(lease_token: nil, lease_expires_at: nil)
      expect(Array.new(3) { claim }.compact.length).to eq(2)
    end

    it 'does not write the endpoint row on success when there is nothing to reset' do
      a = endpoint('a')
      before = endpoint_row(a)[:updated_at]
      expect(Clearinghouse::Webhooks::Breakers.success(app_db, a.id)).to be_nil
      expect(endpoint_row(a)[:updated_at]).to eq(before)
    end
  end
end
