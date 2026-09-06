# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Routes::WebhookEndpoints do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:deps) do
    Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock, log: nil,
                                         webhook_http: WebhookSpecHelpers.egress)
  end
  let(:form) { auth.merge('CONTENT_TYPE' => 'application/x-www-form-urlencoded') }

  def create(body = 'url=https://hooks.example.com/in&enabled_events[]=*')
    post '/v1/webhook_endpoints', body, form
    json_body
  end

  describe 'POST /v1/webhook_endpoints' do
    it 'creates an endpoint pinned to the merchant version and shows the secret once' do
      body = create('url=https://hooks.example.com/in&enabled_events[]=payment_intent.succeeded' \
                    '&enabled_events[]=charge.refunded&description=orders')
      expect(last_response.status).to eq(200)
      expect(body).to include('object' => 'webhook_endpoint', 'url' => 'https://hooks.example.com/in',
                              'enabled_events' => %w[payment_intent.succeeded charge.refunded],
                              'api_version' => merchant.api_version, 'status' => 'enabled',
                              'description' => 'orders', 'disabled_reason' => nil,
                              'created' => clock.now.to_i, 'livemode' => false)
      expect(body['id']).to match(/\Awe_[A-Za-z0-9]{24}\z/)
      expect(body['secret']).to match(/\Awhsec_[A-Za-z0-9_-]{43}\z/)

      get "/v1/webhook_endpoints/#{body['id']}", {}, auth
      expect(json_body).not_to have_key('secret')
      expect(last_response.body).not_to include(body['secret'])
    end

    it 'takes a JSON body and an explicit api_version' do
      post '/v1/webhook_endpoints',
           JSON.generate(url: 'https://hooks.example.com/a', enabled_events: ['*'], api_version: '2026-03-01'),
           auth.merge('CONTENT_TYPE' => 'application/json')
      expect(json_body).to include('api_version' => '2026-03-01', 'enabled_events' => ['*'])
    end

    context 'when the merchant is pinned to an old version' do
      let(:merchant_api_version) { '2026-01-01' }

      it 'defaults the endpoint to that version' do
        expect(create['api_version']).to eq('2026-01-01')
      end
    end

    [
      ['url=http://hooks.example.com/in&enabled_events[]=*', 'url', 'url_invalid', /scheme_not_allowed/],
      ['url=https://internal.example.com/in&enabled_events[]=*', 'url', 'url_invalid', /private/],
      ['url=https://169.254.169.254/latest&enabled_events[]=*', 'url', 'url_invalid', /link_local/],
      ['url=https://2130706433/&enabled_events[]=*', 'url', 'url_invalid', /ambiguous_ip_encoding/],
      ['enabled_events[]=*', 'url', 'parameter_missing', /url/],
      ['url=https://hooks.example.com/in', 'enabled_events', 'parameter_missing', /enabled_events/],
      ['url=https://hooks.example.com/in&enabled_events[]=nope', 'enabled_events', 'parameter_invalid', /nope/],
      ['url=https://hooks.example.com/in&enabled_events[]=*&enabled_events[]=payout.paid', 'enabled_events',
       'parameter_invalid', /cannot be combined/],
      ['url=https://hooks.example.com/in&enabled_events[]=*&api_version=2020-01-01', 'api_version',
       'parameter_invalid', /one of/],
      ['url=https://hooks.example.com/in&enabled_events=*&secret=x', 'secret', 'parameter_unknown', /secret/]
    ].each do |body, param, code, message|
      it "refuses #{body} as #{code} on #{param}" do
        post '/v1/webhook_endpoints', body, form
        expect(last_response.status).to eq(400)
        expect(json_body['error']).to include('type' => 'invalid_request_error', 'param' => param, 'code' => code)
        expect(json_body['error']['message']).to match(message)
      end
    end

    it 'accepts a URL whose name does not resolve yet, since delivery checks again' do
      create('url=https://not-yet.example.com/in&enabled_events[]=*')
      expect(last_response.status).to eq(200)
    end

    it 'caps a merchant at 16 endpoints' do
      16.times { create }
      create
      expect(last_response.status).to eq(400)
      expect(json_body['error']['code']).to eq('webhook_endpoint_limit_reached')
    end
  end

  describe 'retrieve, list, update, delete' do
    it 'lists newest first with pagination' do
      ids = Array.new(3) do
        clock.advance(1)
        create['id']
      end
      get '/v1/webhook_endpoints', { limit: 2 }, auth
      expect(json_body).to include('object' => 'list', 'url' => '/v1/webhook_endpoints', 'has_more' => true)
      expect(json_body['data'].map { |e| e['id'] }).to eq(ids.reverse.first(2))

      get '/v1/webhook_endpoints', { limit: 2, starting_after: ids[1] }, auth
      expect(json_body['has_more']).to be(false)
      expect(json_body['data'].map { |e| e['id'] }).to eq([ids[0]])
    end

    it 'updates the url and events, and re-checks the url' do
      id = create['id']
      post "/v1/webhook_endpoints/#{id}", 'url=https://hooks.example.com/v2&enabled_events[]=payout.paid', form
      expect(json_body).to include('url' => 'https://hooks.example.com/v2', 'enabled_events' => ['payout.paid'])

      post "/v1/webhook_endpoints/#{id}", 'url=https://10.1.2.3/', form
      expect(last_response.status).to eq(400)
      expect(json_body['error']['code']).to eq('url_invalid')
    end

    it 'lets the merchant disable and re-enable an endpoint' do
      id = create['id']
      post "/v1/webhook_endpoints/#{id}", 'disabled=true', form
      expect(json_body).to include('status' => 'disabled', 'disabled_reason' => 'disabled_by_merchant')
      post "/v1/webhook_endpoints/#{id}", 'disabled=false', form
      expect(json_body).to include('status' => 'enabled', 'disabled_reason' => nil)
    end

    it 'deletes an endpoint, after which it is not found' do
      id = create['id']
      delete "/v1/webhook_endpoints/#{id}", {}, auth
      expect(json_body).to eq('id' => id, 'object' => 'webhook_endpoint', 'deleted' => true)
      get "/v1/webhook_endpoints/#{id}", {}, auth
      expect(last_response.status).to eq(404)
      get '/v1/webhook_endpoints', {}, auth
      expect(json_body['data']).to be_empty
      expect(ApiSpecHelpers.db[:webhook_endpoints].where(id: id).get(:deleted_at)).to eq(clock.now)
    end

    it "does not show one merchant's endpoint to another" do
      id = create['id']
      _other, other_key = Clearinghouse::Merchants.create(ApiSpecHelpers.db, clock: clock, name: 'Other',
                                                                             api_version: '2026-09-01')
      other = { 'HTTP_AUTHORIZATION' => "Bearer #{other_key}" }
      get "/v1/webhook_endpoints/#{id}", {}, other
      expect(last_response.status).to eq(404)
      expect(json_body['error']).to include('code' => 'resource_missing', 'param' => 'id')
      delete "/v1/webhook_endpoints/#{id}", {}, other
      expect(last_response.status).to eq(404)
    end
  end

  describe 'POST /v1/webhook_endpoints/:id/roll_secret' do
    it 'returns a new secret and keeps the old one signing for the overlap' do
      created = create
      clock.advance(60)
      post "/v1/webhook_endpoints/#{created['id']}/roll_secret", 'expires_in=3600', form
      expect(json_body['secret']).to match(/\Awhsec_/)
      expect(json_body['secret']).not_to eq(created['secret'])
      expect(json_body['previous_secret_expires_at']).to eq(clock.now.to_i + 3600)

      endpoint = Clearinghouse::Webhooks::Endpoints.find(ApiSpecHelpers.db, merchant.id, created['id'])
      expect(endpoint.secrets.active_secrets(now: clock.now)).to eq([json_body['secret'], created['secret']])
      expect(endpoint.secrets.active_secrets(now: clock.now + 3600)).to eq([json_body['secret']])
    end

    it 'defaults to a 24 hour overlap and allows expiring the old secret at once' do
      id = create['id']
      post "/v1/webhook_endpoints/#{id}/roll_secret", '', form
      expect(json_body['previous_secret_expires_at']).to eq(clock.now.to_i + 86_400)
      post "/v1/webhook_endpoints/#{id}/roll_secret", 'expires_in=0', form
      expect(json_body['previous_secret_expires_at']).to be_nil
    end

    it 'refuses an overlap over 24 hours' do
      post "/v1/webhook_endpoints/#{create['id']}/roll_secret", 'expires_in=86401', form
      expect(json_body['error']).to include('param' => 'expires_in', 'code' => 'parameter_invalid')
    end
  end
end
