# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Routes::Merchants do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:admin) do
    { 'HTTP_AUTHORIZATION' => 'Bearer admin_spec_token', 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
  end

  describe 'POST /v1/merchants' do
    it 'creates a merchant pinned to the latest version and shows its key once' do
      post '/v1/merchants', 'name=Rocket+Rides', admin
      expect(last_response.status).to eq(201)
      expect(json_body).to include('object' => 'account', 'name' => 'Rocket Rides', 'api_version' => '2026-09-01',
                                   'fee_schedule' => { 'percent' => '2.9', 'fixed' => { 'usd' => 30 } },
                                   'payout_schedule' => { 'interval' => 'daily', 'delay_days' => 2 },
                                   'created' => Time.utc(2026, 9, 1, 12).to_i, 'livemode' => false)
      expect(json_body['id']).to match(/\Aacct_[A-Za-z0-9]{24}\z/)
      expect(json_body['secret_key']).to match(/\Ask_test_[A-Za-z0-9]{24}\z/)
    end

    it 'stores only a digest of the key' do
      post '/v1/merchants', 'name=Rocket+Rides', admin
      key = json_body['secret_key']
      row = ApiSpecHelpers.db[:merchants].where(id: json_body['id']).first
      expect(row[:secret_key_hash]).to eq(Digest::SHA256.hexdigest(key))
      expect(row.values.map(&:to_s)).not_to include(key)
    end

    it 'takes a pinned version, fee schedule and payout schedule' do
      post '/v1/merchants', 'name=Old+Co&api_version=2026-03-01&fee_percent=1.75&fee_fixed[usd]=25&fee_fixed[jpy]=0' \
                            '&payout_schedule[interval]=weekly&payout_schedule[delay_days]=7', admin
      expect(last_response.status).to eq(201)
      expect(json_body).to include('api_version' => '2026-03-01',
                                   'fee_schedule' => { 'percent' => '1.75', 'fixed' => { 'usd' => 25, 'jpy' => 0 } },
                                   'payout_schedule' => { 'interval' => 'weekly', 'delay_days' => 7 })
      found = Clearinghouse::Merchants.find(ApiSpecHelpers.db, json_body['id'])
      expect(found.fee_schedule.rate_scaled).to eq(175_000)
      expect(found.fee_schedule.fixed_minor).to eq('usd' => 25, 'jpy' => 0)
    end

    it 'renders the new account at the version the merchant is pinned to, and the key works' do
      post '/v1/merchants', 'name=Old+Co&api_version=2026-03-01', admin
      expect(last_response.headers['clearinghouse-version']).to eq('2026-09-01')
      get '/v1/account', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{json_body['secret_key']}" }
      expect(last_response.headers['clearinghouse-version']).to eq('2026-03-01')
      expect(json_body['name']).to eq('Old Co')
    end

    [
      ['', 'name', 'parameter_missing'],
      ['name=X&api_version=2025-01-01', 'api_version', 'parameter_invalid'],
      ['name=X&fee_percent=2.9.1', 'fee_percent', 'parameter_invalid'],
      ['name=X&fee_percent=101', 'fee_percent', 'parameter_invalid'],
      ['name=X&fee_fixed[xyz]=1', 'fee_fixed[xyz]', 'parameter_invalid'],
      ['name=X&fee_fixed[usd]=-1', 'fee_fixed[usd]', 'parameter_invalid'],
      ['name=X&fee_fixed=30', 'fee_fixed', 'parameter_invalid'],
      ['name=X&payout_schedule[interval]=hourly', 'payout_schedule[interval]', 'parameter_invalid'],
      ['name=X&payout_schedule[delay_days]=31', 'payout_schedule[delay_days]', 'parameter_invalid'],
      ['name=X&payout_schedule[anchor]=monday', 'payout_schedule[anchor]', 'parameter_unknown'],
      ['name=X&secret_key=sk_test_mine', 'secret_key', 'parameter_unknown']
    ].each do |body, param, code|
      it "rejects #{body.inspect} naming #{param}" do
        post '/v1/merchants', body, admin
        expect(last_response.status).to eq(400)
        expect(json_body['error']).to include('param' => param, 'code' => code)
      end
    end

    it 'needs the admin token' do
      post '/v1/merchants', 'name=X', admin.merge('HTTP_AUTHORIZATION' => 'Bearer wrong')
      expect(last_response.status).to eq(401)
      expect(json_body['error']).to include('type' => 'authentication_error', 'code' => 'admin_token_invalid')
    end

    it 'does not accept a merchant secret key in place of the admin token' do
      post '/v1/merchants', 'name=X', admin.merge(auth)
      expect(last_response.status).to eq(401)
    end

    context 'when no admin token is configured' do
      let(:deps) { Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock) }

      it 'is disabled' do
        post '/v1/merchants', 'name=X', admin
        expect(last_response.status).to eq(401)
        expect(json_body['error']['message']).to include('disabled')
      end
    end
  end

  describe 'secret key authentication' do
    it 'accepts a Bearer key' do
      get '/v1/account', {}, auth
      expect(last_response.status).to eq(200)
      expect(json_body).to include('id' => merchant.id, 'name' => 'Rocket Rides')
      expect(json_body).not_to have_key('secret_key')
    end

    it 'accepts the key as the Basic auth username, as curl -u sends it' do
      get '/v1/account', {}, { 'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64("#{secret_key}:")}" }
      expect(json_body['id']).to eq(merchant.id)
    end

    it 'rejects a request with no key' do
      get '/v1/account'
      expect(last_response.status).to eq(401)
      expect(json_body['error']).to include('type' => 'authentication_error', 'code' => 'api_key_missing')
      expect(last_response.headers['clearinghouse-should-retry']).to eq('false')
    end

    it 'rejects an unknown key and shows only its last four characters' do
      wrong = Clearinghouse::Ids.generate('sk_test')
      get '/v1/account', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{wrong}" }
      expect(last_response.status).to eq(401)
      expect(json_body['error']).to include('code' => 'api_key_invalid',
                                            'message' => "Invalid API Key provided: sk_test_****#{wrong[-4..]}")
      expect(last_response.body).not_to include(wrong[8..-5])
    end

    it 'rejects a malformed key without querying' do
      allow(ApiSpecHelpers.db).to receive(:[]).and_call_original
      get '/v1/account', {}, { 'HTTP_AUTHORIZATION' => 'Bearer pk_live_abc' }
      expect(json_body['error']['code']).to eq('api_key_invalid')
      expect(ApiSpecHelpers.db).not_to have_received(:[]).with(:merchants)
    end

    it 'rejects an unknown scheme' do
      get '/v1/account', {}, { 'HTTP_AUTHORIZATION' => "Token #{secret_key}" }
      expect(last_response.status).to eq(401)
    end

    it 'authenticates unknown /v1 routes before saying they do not exist' do
      get '/v1/nothing_here'
      expect(last_response.status).to eq(401)
    end

    it 'does not need a key outside /v1' do
      get '/healthz'
      expect(last_response.status).to eq(200)
    end

    it 'puts the merchant id in the request log' do
      log = StringIO.new
      logged = Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock, log: log)
      Rack::MockRequest.new(Clearinghouse::Api.rack_app(logged)).get('/v1/account', auth)
      expect(JSON.parse(log.string)).to include('merchant' => merchant.id, 'status' => 200)
    end

    it 'rejects unknown parameters on GET /v1/account' do
      get '/v1/account?foo=1', {}, auth
      expect(json_body['error']).to include('param' => 'foo', 'code' => 'parameter_unknown')
    end
  end
end
