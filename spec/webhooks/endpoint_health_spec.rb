# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::EndpointHealth, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { Clearinghouse::Merchants.create(app_db, clock: clock, name: 'M', api_version: '2026-09-01').first }
  let(:hook) { WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id) }

  def row
    app_db[:webhook_endpoints].where(id: hook.id).first
  end

  def fail_once
    app_db.transaction { described_class.failure(app_db, hook.id, clock: clock) }
  end

  it 'starts a run at the first failure and clears it on success' do
    expect(fail_once).to eq(:failing)
    started = clock.now
    clock.advance(3600)
    fail_once
    expect(row).to include(failing_since: started, last_failure_at: clock.now)
    described_class.success(app_db, hook.id)
    expect(row).to include(failing_since: nil, last_failure_at: nil)
  end

  it 'disables after five days of failures that never paused for a day' do
    started = clock.now
    fail_once
    (5 * 4).times do
      clock.advance(6 * 3600)
      disabled = fail_once == :disabled
      expect(disabled).to eq(clock.now - started >= 5 * 86_400)
      break if disabled
    end
    expect(row).to include(status: 'disabled', disabled_reason: 'failing_continuously')
    expect(clock.now - started).to eq(5 * 86_400)
  end

  it 'starts a new run after a quiet day, so two failures a week apart are not a week of failing' do
    fail_once
    clock.advance(7 * 86_400)
    expect(fail_once).to eq(:failing)
    expect(row[:failing_since]).to eq(clock.now)
  end

  it 'does not disable an endpoint the merchant already disabled, or emit twice' do
    app_db[:webhook_endpoints].where(id: hook.id)
                              .update(status: 'disabled', disabled_reason: 'disabled_by_merchant',
                                      failing_since: clock.now - (6 * 86_400), last_failure_at: clock.now - 60)
    expect(fail_once).to eq(:failing)
    expect(row[:disabled_reason]).to eq('disabled_by_merchant')
    expect(app_db[:events].count).to eq(0)
  end

  describe 'through the worker' do
    let(:server) { LocalHttpServer.new { |socket, _| LocalHttpServer.respond(socket, 500) } }
    let(:failing) do
      WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id,
                                                 url: "http://127.0.0.1:#{server.port}/")
    end
    let(:other) do
      WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id,
                                                 url: 'https://hooks.example.com/other',
                                                 events: %w[webhook_endpoint.disabled])
    end

    after { server.stop }

    it 'disables the endpoint, fails its pending deliveries, and tells the merchant by event' do
      failing
      other
      first = WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id)
      second = WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id)
      dispatcher = WebhookSpecHelpers.dispatcher(app_db, clock: clock)
      dispatcher.run_once
      # Five days of failures are behind it; this attempt makes it official.
      app_db[:webhook_endpoints].where(id: failing.id)
                                .update(failing_since: clock.now - (5 * 86_400), last_failure_at: clock.now - 600)

      worker = WebhookSpecHelpers.worker(app_db, clock: clock)
      claim = Clearinghouse::Webhooks::FifoQueue.new.claim(app_db, now: clock.now, lease_seconds: 60, token: 't')
      expect(worker.deliver(claim).state).to eq(:failed)

      expect(app_db[:webhook_endpoints].where(id: failing.id).first)
        .to include(status: 'disabled', disabled_reason: 'failing_continuously')
      attempted, untried = claim.event_id == first ? [first, second] : [second, first]
      expect(WebhookSpecHelpers.delivery(app_db, attempted)).to include(status: 'failed', last_status: 500,
                                                                        attempts: 1)
      expect(WebhookSpecHelpers.delivery(app_db, untried)).to include(status: 'failed', attempts: 0,
                                                                      last_error: 'endpoint_disabled')

      event = app_db[:events].where(type: 'webhook_endpoint.disabled').first
      expect(Clearinghouse::DB.from_json(event[:data]))
        .to include('id' => failing.id, 'object' => 'webhook_endpoint', 'status' => 'disabled',
                    'disabled_reason' => 'failing_continuously')
      expect(Clearinghouse::DB.from_json(event[:data])).not_to have_key('secret')

      dispatcher.run_once
      expect(app_db[:webhook_deliveries].where(event_id: event[:id]).select_map(:endpoint_id)).to eq([other.id])
    end
  end
end
