# typed: false
# frozen_string_literal: true

# One hung endpoint against a small worker pool, over real sockets: with isolation the
# hung endpoint holds at most max_in_flight workers and then none once its breaker
# opens, and the healthy endpoint's backlog goes out at once. The FIFO baseline, same
# pool, same timeouts, spends its workers on the hung endpoint first.
RSpec.describe 'Webhook isolation against a hung endpoint', :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { Clearinghouse::Merchants.create(app_db, clock: clock, name: 'M', api_version: '2026-09-01').first }
  let(:concurrency) { { now: 0, max: 0 } }
  let(:lock) { Mutex.new }
  let(:hung) do
    LocalHttpServer.new do |_socket, _request|
      lock.synchronize do
        concurrency[:now] += 1
        concurrency[:max] = [concurrency[:max], concurrency[:now]].max
      end
      sleep 2
    ensure
      lock.synchronize { concurrency[:now] -= 1 }
    end
  end
  let(:healthy) { LocalHttpServer.new { |socket, _| LocalHttpServer.respond(socket, 200) } }
  let(:http) do
    Clearinghouse::Webhooks::SafeHttp.new(resolver: FakeResolver.new({}), test_mode: true, connect_timeout: 0.5,
                                          read_timeout: 0.4, total_timeout: 1.0)
  end

  after do
    hung.stop
    healthy.stop
  end

  def endpoint(server, events)
    WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id,
                                               url: "http://127.0.0.1:#{server.port}/", events: events)
  end

  # Twelve events for the hung endpoint, then twelve for the healthy one, so a FIFO
  # queue meets every hung delivery first.
  def backlog
    endpoint(hung, ['payment_intent.payment_failed'])
    endpoint(healthy, ['payment_intent.succeeded'])
    12.times do
      clock.advance(1)
      WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id, type: 'payment_intent.payment_failed')
    end
    12.times do
      clock.advance(1)
      WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id)
    end
    WebhookSpecHelpers.dispatcher(app_db, clock: clock).run_until_idle
  end

  # Seconds until the healthy server has all twelve.
  def run_pool(queue)
    pool = Clearinghouse::Webhooks::WorkerPool.new(threads: 4, idle_sleep: 0.01) do |i|
      WebhookSpecHelpers.worker(app_db, clock: clock, http: http, queue: queue, seed: i)
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pool.start
    sleep 0.01 until healthy.requests.length >= 12 || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 15
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    pool.stop
    elapsed
  end

  it 'caps the hung endpoint at max_in_flight, opens its breaker, and delivers the healthy backlog at once' do
    backlog
    breaker = Clearinghouse::Webhooks::CircuitBreaker.new(failure_threshold: 2, cooldown: 3600.0)
    elapsed = run_pool(Clearinghouse::Webhooks::IsolatedQueue.new(max_in_flight: 2, breaker: breaker))

    expect(healthy.requests.length).to eq(12)
    # Two workers were free for the healthy endpoint from the start.
    expect(elapsed).to be < 1.5
    # The server counts a connection until its 2 second sleep ends, after the client
    # gave up, so this is an upper bound on what the workers held at once.
    expect(concurrency[:max]).to be <= 2
    expect(hung.requests.length).to eq(2)
    expect(app_db[:webhook_endpoints].where(url: "http://127.0.0.1:#{hung.port}/").get(:breaker_state)).to eq('open')
  end

  it 'lets the same hung endpoint take every worker under FIFO' do
    backlog
    elapsed = run_pool(Clearinghouse::Webhooks::FifoQueue.new)

    expect(healthy.requests.length).to eq(12)
    # Twelve hung deliveries at 0.4 s each across four workers come first.
    expect(elapsed).to be > 1.1
    expect(hung.requests.length).to eq(12)
  end
end
