# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::Worker, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { Clearinghouse::Merchants.create(app_db, clock: clock, name: 'M', api_version: '2026-09-01').first }
  let(:servers) { [] }
  let(:statuses) { [] }
  let(:server) do
    serve do |socket, _request|
      LocalHttpServer.respond(socket, statuses.shift || 200, 'ok')
    end
  end
  let(:worker) { WebhookSpecHelpers.worker(app_db, clock: clock) }

  after { servers.each(&:stop) }

  def serve(&handler)
    LocalHttpServer.new(&handler).tap { |s| servers << s }
  end

  def endpoint(url: "http://127.0.0.1:#{server.port}/hooks", api_version: '2026-09-01', events: ['*'])
    WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id, url: url,
                                               api_version: api_version, events: events)
  end

  def emit_and_dispatch(type = 'payment_intent.succeeded')
    id = WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id, type: type)
    WebhookSpecHelpers.dispatcher(app_db, clock: clock).run_once
    id
  end

  def delivery(event_id)
    WebhookSpecHelpers.delivery(app_db, event_id)
  end

  def golden(version)
    path = File.expand_path("../fixtures/golden/#{version}/event_payment_intent_succeeded.json", __dir__)
    JSON.parse(File.read(path))
  end

  describe 'a successful delivery' do
    it 'posts the event, signed, and records success' do
      hook = endpoint
      event_id = emit_and_dispatch
      result = worker.work_once
      expect(result).to have_attributes(state: :succeeded, endpoint_id: hook.id)
      expect(worker.work_once).to be_nil

      request = server.requests.fetch(0)
      expect(request.request_line).to eq('POST /hooks HTTP/1.1')
      body = JSON.parse(request.body)
      expect(body).to include('id' => event_id, 'object' => 'event', 'type' => 'payment_intent.succeeded',
                              'api_version' => '2026-09-01', 'created' => clock.now.to_i)
      verified = Clearinghouse::Webhooks::Signature.verify(
        payload: request.body, header: request.headers.fetch('clearinghouse-signature'),
        secrets: [hook.secrets.current], now: clock.now.to_i
      )
      expect(verified).to be_valid
      expect(verified.timestamp).to eq(clock.now.to_i)
      expect(delivery(event_id)).to include(status: 'succeeded', attempts: 1, last_status: 200,
                                            succeeded_at: clock.now, lease_token: nil)
    end

    %w[2026-01-01 2026-03-01 2026-06-01 2026-09-01].each do |version|
      it "renders the payload at the endpoint's pinned version #{version}" do
        endpoint(api_version: version)
        emit_and_dispatch
        worker.work_once
        body = JSON.parse(server.requests.fetch(0).body)
        expect(body['api_version']).to eq(version)
        expect(body['data']).to eq(golden(version)['data'])
      end
    end

    it 'renders each endpoint at its own version from the same event' do
      old = endpoint(api_version: '2026-01-01')
      new = endpoint(api_version: '2026-09-01')
      emit_and_dispatch
      worker.drain
      bodies = server.requests.to_h do |r|
        secret_owner = [old, new].find do |e|
          Clearinghouse::Webhooks::Signature.verify(payload: r.body, header: r.headers['clearinghouse-signature'],
                                                    secrets: [e.secrets.current], now: clock.now.to_i).valid?
        end
        [secret_owner.id, JSON.parse(r.body)]
      end
      expect(bodies[old.id]['data']['object']).to have_key('amount_captured')
      expect(bodies[new.id]['data']['object']).to have_key('amount_received')
    end

    it 'signs with both secrets during a rotation, and only the new one after it' do
      hook = endpoint
      rolled = Clearinghouse::Webhooks::Endpoints.roll_secret(app_db, clock: clock, endpoint: hook, overlap: 3600)
      emit_and_dispatch
      worker.work_once
      header = server.requests.fetch(0).headers['clearinghouse-signature']
      expect(header.scan('v1=').length).to eq(2)
      [hook.secrets.current, rolled.secrets.current].each do |secret|
        expect(Clearinghouse::Webhooks::Signature.verify(payload: server.requests[0].body, header: header,
                                                         secrets: [secret], now: clock.now.to_i)).to be_valid
      end

      clock.advance(3600)
      emit_and_dispatch
      worker.work_once
      late = server.requests.fetch(1)
      expect(late.headers['clearinghouse-signature'].scan('v1=').length).to eq(1)
      old_only = Clearinghouse::Webhooks::Signature.verify(payload: late.body,
                                                           header: late.headers['clearinghouse-signature'],
                                                           secrets: [hook.secrets.current], now: clock.now.to_i)
      expect(old_only).not_to be_valid
    end
  end

  describe 'failures' do
    it 'schedules a retry after a 500, with full-jitter backoff from the seeded rng' do
      endpoint
      statuses.push(500)
      event_id = emit_and_dispatch
      expect(worker.work_once.state).to eq(:retrying)
      row = delivery(event_id)
      expected_delay = Random.new(1).rand * 60.0
      expect(row).to include(status: 'pending', attempts: 1, last_status: 500, last_error: 'http_500',
                             lease_token: nil)
      expect(row[:next_attempt_at]).to be_within(0.001).of(clock.now + expected_delay)
      expect(worker.work_once).to be_nil

      clock.advance_to(row[:next_attempt_at])
      expect(worker.work_once.state).to eq(:succeeded)
      expect(delivery(event_id)).to include(status: 'succeeded', attempts: 2)
    end

    it 'retries a timeout' do
      hang = serve { |_socket, _| sleep 3 }
      endpoint(url: "http://127.0.0.1:#{hang.port}/")
      event_id = emit_and_dispatch
      fast = WebhookSpecHelpers.worker(app_db, clock: clock, http: WebhookSpecHelpers.egress(read_timeout: 0.2))
      expect(fast.work_once.state).to eq(:retrying)
      expect(delivery(event_id)[:last_error]).to eq('timeout_read')
    end

    it 'fails a blocked URL at once and does not retry it' do
      hook = endpoint(url: 'https://hooks.example.com/in')
      # The name resolved to a public address at registration and to an internal one now.
      http = Clearinghouse::Webhooks::SafeHttp.new(resolver: FakeResolver.new('hooks.example.com' => [['10.0.0.7']]))
      event_id = emit_and_dispatch
      result = WebhookSpecHelpers.worker(app_db, clock: clock, http: http).work_once
      expect(result.state).to eq(:failed)
      expect(delivery(event_id)).to include(status: 'failed', attempts: 1, failed_at: clock.now)
      expect(delivery(event_id)[:last_error]).to start_with('blocked: private')
      expect(hook.id).to eq(result.endpoint_id)
    end

    it 'fails a delivery whose endpoint was disabled after it was claimed' do
      hook = endpoint
      event_id = emit_and_dispatch
      claim = Clearinghouse::Webhooks::FifoQueue.new.claim(app_db, now: clock.now, lease_seconds: 60, token: 't')
      app_db[:webhook_endpoints].where(id: hook.id).update(status: 'disabled', disabled_reason: 'test')
      expect(worker.deliver(claim).state).to eq(:failed)
      expect(delivery(event_id)).to include(status: 'failed', last_error: 'endpoint_disabled')
      expect(server.requests).to be_empty
    end

    it 'retries after an internal error without blaming the endpoint' do
      hook = endpoint
      event_id = emit_and_dispatch
      broken_engine = Class.new(Clearinghouse::Versioning::Engine) do
        def render_event(*) = raise(KeyError, 'boom')
      end
      broken = broken_engine.new(registry: Clearinghouse::Versioning.registry,
                                 expander: Clearinghouse::Versioning.default_expander)
      log = StringIO.new
      result = WebhookSpecHelpers.worker(app_db, clock: clock, versioning: broken, log: log).work_once
      expect(result.state).to eq(:retrying)
      expect(delivery(event_id)[:last_error]).to eq('internal_error: KeyError: boom')
      expect(app_db[:webhook_endpoints].where(id: hook.id).get(:failing_since)).to be_nil
      expect(log.string).to include('"exception":"KeyError"')
    end
  end

  describe 'the circuit breaker' do
    it 'opens after consecutive failures, logs it, and closes on the next success' do
      hook = endpoint
      3.times { emit_and_dispatch }
      statuses.push(500, 500, 500)
      log = StringIO.new
      breaker = Clearinghouse::Webhooks::CircuitBreaker.new(failure_threshold: 3, cooldown: 30.0)
      queue = Clearinghouse::Webhooks::IsolatedQueue.new(max_in_flight: 1, breaker: breaker)
      isolated = WebhookSpecHelpers.worker(app_db, clock: clock, queue: queue, log: log, name: 'w')
      3.times do
        expect(isolated.work_once.state).to eq(:retrying)
        clock.advance(61)
      end
      row = app_db[:webhook_endpoints].where(id: hook.id).first
      expect(row).to include(breaker_state: 'open', consecutive_failures: 3)
      expect(log.string).to include(%("breaker":"#{hook.id}","from":"closed","to":"open"))

      clock.advance_to([row[:breaker_retry_at], clock.now].max)
      expect(isolated.work_once.state).to eq(:succeeded)
      expect(app_db[:webhook_endpoints].where(id: hook.id).get(:breaker_state)).to eq('closed')
      expect(log.string).to include('"from":"half_open","to":"closed"')
    end

    it 'leaves the breaker alone under the FIFO baseline' do
      hook = endpoint
      emit_and_dispatch
      statuses.push(500)
      WebhookSpecHelpers.worker(app_db, clock: clock, queue: Clearinghouse::Webhooks::FifoQueue.new).work_once
      expect(app_db[:webhook_endpoints].where(id: hook.id).first).to include(breaker_state: 'closed',
                                                                             consecutive_failures: 0)
    end
  end

  describe 'claims and leases' do
    it 'never hands a leased delivery to a second worker until the lease expires' do
      endpoint
      event_id = emit_and_dispatch
      queue = Clearinghouse::Webhooks::FifoQueue.new
      first = queue.claim(app_db, now: clock.now, lease_seconds: 60, token: 'a')
      expect(first).to have_attributes(event_id: event_id, attempts: 1, lease_token: 'a')
      expect(queue.claim(app_db, now: clock.now, lease_seconds: 60, token: 'b')).to be_nil
      clock.advance(59)
      expect(queue.claim(app_db, now: clock.now, lease_seconds: 60, token: 'b')).to be_nil

      # The first worker died. At expiry the delivery is claimable again, and the
      # crashed attempt still counts.
      clock.advance(1)
      second = queue.claim(app_db, now: clock.now, lease_seconds: 60, token: 'b')
      expect(second).to have_attributes(event_id: event_id, attempts: 2, lease_token: 'b')
    end

    it 'ignores a failure from a worker that lost its lease, but keeps its success' do
      endpoint
      event_id = emit_and_dispatch
      queue = Clearinghouse::Webhooks::FifoQueue.new
      stale = queue.claim(app_db, now: clock.now, lease_seconds: 60, token: 'stale')
      clock.advance(61)
      fresh = queue.claim(app_db, now: clock.now, lease_seconds: 60, token: 'fresh')

      statuses.push(500)
      expect(worker.deliver(stale).state).to eq(:lease_lost)
      expect(delivery(event_id)).to include(status: 'pending', lease_token: 'fresh')

      expect(worker.deliver(stale).state).to eq(:succeeded)
      expect(delivery(event_id)).to include(status: 'succeeded', lease_token: nil)
      statuses.push(500)
      expect(worker.deliver(fresh).state).to eq(:lease_lost)
      expect(delivery(event_id)[:status]).to eq('succeeded')
    end

    it 'redelivers after a crash between the POST and the record: at least once' do
      endpoint
      event_id = emit_and_dispatch
      claim = Clearinghouse::Webhooks::FifoQueue.new.claim(app_db, now: clock.now, lease_seconds: 60, token: 'x')
      # The crashed worker got as far as sending.
      hook = Clearinghouse::Webhooks::Endpoints.find(app_db, merchant.id, claim.endpoint_id)
      WebhookSpecHelpers.egress.post(hook.url, body: '{}', headers: {})
      clock.advance(60)
      expect(worker.work_once.state).to eq(:succeeded)
      expect(server.requests.length).to eq(2)
      expect(delivery(event_id)).to include(status: 'succeeded', attempts: 2)
    end

    it 'gives 200 concurrent claims to 8 workers without claiming anything twice' do
      endpoint(url: 'https://hooks.example.com/in')
      200.times { WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id) }
      WebhookSpecHelpers.dispatcher(app_db, clock: clock).run_until_idle
      queue = Clearinghouse::Webhooks::FifoQueue.new
      claimed = Array.new(8) do |i|
        Thread.new do
          ids = []
          while (claim = queue.claim(app_db, now: clock.now, lease_seconds: 60, token: "w#{i}"))
            ids << claim.delivery_id
          end
          ids
        end
      end.flat_map(&:value)
      expect(claimed.length).to eq(200)
      expect(claimed.uniq.length).to eq(200)
    end

    it 'claims the oldest event first' do
      endpoint
      ids = Array.new(3) do
        clock.advance(1)
        emit_and_dispatch
      end
      queue = Clearinghouse::Webhooks::FifoQueue.new
      order = Array.new(3) { queue.claim(app_db, now: clock.now, lease_seconds: 60, token: 't').event_id }
      expect(order).to eq(ids)
    end
  end
end
