# typed: false
# frozen_string_literal: true

# POST /v1/events/:id/retry, the manual resend.
RSpec.describe Clearinghouse::Api::Routes::Events do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:deps) do
    Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock, log: nil,
                                         webhook_http: WebhookSpecHelpers.egress)
  end
  let(:db) { ApiSpecHelpers.db }
  let(:form) { auth.merge('CONTENT_TYPE' => 'application/x-www-form-urlencoded') }
  let!(:hook) { WebhookSpecHelpers.create_endpoint(db, clock: clock, merchant_id: merchant.id) }

  def emit(type = 'payment_intent.succeeded')
    WebhookSpecHelpers.emit(db, clock: clock, merchant_id: merchant.id, type: type)
  end

  def retry_event(event_id, endpoint_id = hook.id)
    post "/v1/events/#{event_id}/retry", "webhook_endpoint=#{endpoint_id}", form
    json_body
  end

  it 'gives a failed delivery exactly one more attempt, due now' do
    event_id = emit
    WebhookSpecHelpers.dispatcher(db, clock: clock).run_once
    db[:webhook_deliveries].update(status: 'failed', failed_at: clock.now, attempts: 21, last_error: 'http_500')
    clock.advance(86_400)
    body = retry_event(event_id)
    expect(last_response.status).to eq(200)
    expect(body).to include('object' => 'webhook_delivery', 'event' => event_id, 'webhook_endpoint' => hook.id,
                            'status' => 'pending', 'attempts' => 21, 'next_attempt' => clock.now.to_i)
    expect(WebhookSpecHelpers.delivery(db, event_id)).to include(retry_deadline_at: clock.now, failed_at: nil)
  end

  it 'makes a pending delivery due now and keeps its retry window' do
    event_id = emit
    WebhookSpecHelpers.dispatcher(db, clock: clock).run_once
    deadline = WebhookSpecHelpers.delivery(db, event_id)[:retry_deadline_at]
    db[:webhook_deliveries].update(next_attempt_at: clock.now + 3600)
    retry_event(event_id)
    expect(WebhookSpecHelpers.delivery(db, event_id)).to include(next_attempt_at: clock.now,
                                                                 retry_deadline_at: deadline)
  end

  it 'creates a delivery for an event the endpoint never received' do
    event_id = emit
    retry_event(event_id)
    expect(db[:webhook_deliveries].where(event_id: event_id, endpoint_id: hook.id).count).to eq(1)
  end

  [
    ['a disabled endpoint', ->(ctx) { ctx.db[:webhook_endpoints].update(status: 'disabled', disabled_reason: 'x') },
     /disabled/],
    ['an event older than 30 days', ->(ctx) { ctx.clock.advance((30 * 86_400) + 1) }, /30 days/]
  ].each do |name, setup, message|
    it "refuses #{name}" do
      event_id = emit
      hook
      setup.call(self)
      body = retry_event(event_id)
      expect(last_response.status).to eq(400)
      expect(body['error']).to include('code' => 'webhook_resend_refused', 'param' => 'webhook_endpoint')
      expect(body['error']['message']).to match(message)
    end
  end

  it 'refuses an endpoint not subscribed to the event type' do
    payouts = WebhookSpecHelpers.create_endpoint(db, clock: clock, merchant_id: merchant.id, events: ['payout.paid'])
    body = retry_event(emit, payouts.id)
    expect(body['error']['message']).to include('not subscribed')
  end

  it '404s an unknown endpoint or event' do
    retry_event(emit, 'we_nope')
    expect(json_body['error']).to include('code' => 'resource_missing', 'param' => 'webhook_endpoint')
    retry_event('evt_nope')
    expect(last_response.status).to eq(404)
  end
end
