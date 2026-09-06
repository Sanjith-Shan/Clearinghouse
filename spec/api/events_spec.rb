# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Routes::Events do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:intent) { WebhookSpecHelpers.payment_intent }

  def emit(type = 'payment_intent.succeeded', object = intent, merchant_id: merchant.id)
    Clearinghouse::Events.emit!(ApiSpecHelpers.db, merchant_id: merchant_id, type: type, object: object, clock: clock)
  end

  def golden(version)
    path = File.expand_path("../fixtures/golden/#{version}/event_payment_intent_succeeded.json", __dir__)
    JSON.parse(File.read(path))
  end

  it 'retrieves an event at the latest version' do
    id = emit
    get "/v1/events/#{id}", {}, auth
    expect(last_response.status).to eq(200)
    expect(json_body).to eq('id' => id, 'object' => 'event', 'type' => 'payment_intent.succeeded',
                            'created' => clock.now.to_i, 'api_version' => '2026-09-01',
                            'data' => { 'object' => intent })
  end

  %w[2026-01-01 2026-03-01 2026-06-01 2026-09-01].each do |version|
    it "renders data.object at the caller's version #{version}, matching the golden file" do
      id = emit
      get "/v1/events/#{id}", {}, auth.merge('HTTP_CLEARINGHOUSE_VERSION' => version)
      expect(json_body['api_version']).to eq(version)
      expect(last_response.headers['clearinghouse-version']).to eq(version)
      expect(json_body['data']).to eq(golden(version)['data'])
    end
  end

  it 'lists newest first, filters by type, and pages' do
    first = emit
    clock.advance(1)
    second = emit('payment_intent.canceled')
    clock.advance(1)
    third = emit
    get '/v1/events', {}, auth
    expect(json_body).to include('object' => 'list', 'url' => '/v1/events', 'has_more' => false)
    expect(json_body['data'].map { |e| e['id'] }).to eq([third, second, first])

    get '/v1/events', { type: 'payment_intent.succeeded', limit: 1 }, auth
    expect(json_body['data'].map { |e| e['id'] }).to eq([third])
    expect(json_body['has_more']).to be(true)

    get '/v1/events', { starting_after: second }, auth
    expect(json_body['data'].map { |e| e['id'] }).to eq([first])
  end

  it "hides another merchant's events" do
    other, = Clearinghouse::Merchants.create(ApiSpecHelpers.db, clock: clock, name: 'Other', api_version: '2026-09-01')
    id = emit(merchant_id: other.id)
    get "/v1/events/#{id}", {}, auth
    expect(last_response.status).to eq(404)
    get '/v1/events', {}, auth
    expect(json_body['data']).to be_empty
  end
end
