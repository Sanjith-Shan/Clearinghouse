# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::App do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:app_class) do
    pi = fixture('payment_intent')
    Class.new(described_class) do
      get('/v1/test_intent') { respond(pi) }
      post('/v1/test_capture') do
        respond({ 'id' => 'x', 'object' => 'echo', 'params' => versioned_params('payment_intents.capture').raw })
      end
    end
  end

  context 'when the merchant is pinned to an older version' do
    let(:merchant_api_version) { '2026-03-01' }

    it 'renders at the pinned version' do
      get '/v1/test_intent', {}, auth
      expect(last_response.headers['clearinghouse-version']).to eq('2026-03-01')
      expect(json_body).to include('amount_received' => 2000, 'failure_code' => nil)
    end

    it 'lets the header override the pin for one request' do
      get '/v1/test_intent', {}, auth.merge('HTTP_CLEARINGHOUSE_VERSION' => '2026-09-01')
      expect(json_body['payment_method']).to eq('pm_card_visa')
    end
  end

  it 'renders at the latest version by default and says so' do
    get '/v1/test_intent', {}, auth
    expect(last_response.headers['clearinghouse-version']).to eq('2026-09-01')
    expect(json_body).to eq(fixture('payment_intent'))
  end

  it 'renders at the version in the Clearinghouse-Version header' do
    get '/v1/test_intent', {}, auth.merge('HTTP_CLEARINGHOUSE_VERSION' => '2026-01-01')
    expect(last_response.headers['clearinghouse-version']).to eq('2026-01-01')
    expect(json_body).to include('amount_captured' => 2000, 'failure_code' => nil)
    expect(json_body['payment_method']).to include('object' => 'payment_method')
  end

  it 'rejects an unknown version rather than guessing' do
    get '/v1/test_intent', {}, auth.merge('HTTP_CLEARINGHOUSE_VERSION' => '2026-02-30')
    expect(last_response.status).to eq(400)
    expect(json_body['error']).to include('type' => 'invalid_request_error', 'code' => 'api_version_invalid')
    expect(json_body['error']['message']).to include('2026-01-01, 2026-03-01, 2026-06-01, 2026-09-01')
  end

  it 'applies expand[] from the query string' do
    get '/v1/test_intent?expand[]=payment_method', {}, auth
    expect(json_body['payment_method']).to include('id' => 'pm_card_visa', 'object' => 'payment_method')
  end

  it 'turns a bad expand path into a parameter error' do
    get '/v1/test_intent?expand[]=status', {}, auth
    expect(last_response.status).to eq(400)
    expect(json_body['error']).to include('param' => 'expand', 'code' => 'parameter_invalid',
                                          'message' => 'This property cannot be expanded (status).')
  end

  it 'logs the version the request was rendered at' do
    log = StringIO.new
    logged = Clearinghouse::Api::Dependencies.new(db: deps.db, clock: clock, log: log)
    Rack::MockRequest.new(Clearinghouse::Api::RequestLogger.new(app_class.new(logged), logged))
                     .get('/v1/test_intent', auth.merge('HTTP_CLEARINGHOUSE_VERSION' => '2026-06-01'))
    expect(JSON.parse(log.string)).to include('api_version' => '2026-06-01', 'merchant' => merchant.id)
  end

  context 'with a change that renamed a request parameter' do
    let(:merchant_api_version) { '2026-02-01' }
    let(:deps) do
      rename = Class.new(Clearinghouse::Versioning::VersionChange) do
        def version = '2026-02-01'
        def description = 'rename'
        def resources = ['payment_intent']
        def transform(object) = object
        def request_endpoints = ['payment_intents.capture']

        def transform_request(_endpoint, params)
          Clearinghouse::Versioning::VersionChange.rename_key(params, 'amount', 'amount_to_capture')
        end
      end.new
      engine = Clearinghouse::Versioning::Engine.new(
        registry: Clearinghouse::Versioning::Registry.new(initial: '2026-01-01', changes: [rename]),
        expander: Clearinghouse::Versioning::Expander.new
      )
      Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock, versioning: engine)
    end

    it 'rewrites what an old caller sends' do
      post '/v1/test_capture', 'amount=500', auth.merge('CONTENT_TYPE' => 'application/x-www-form-urlencoded',
                                                        'HTTP_CLEARINGHOUSE_VERSION' => '2026-01-01')
      expect(json_body['params']).to eq('amount_to_capture' => '500')
    end

    it 'leaves a current caller alone' do
      post '/v1/test_capture', 'amount_to_capture=500',
           auth.merge('CONTENT_TYPE' => 'application/x-www-form-urlencoded')
      expect(json_body['params']).to eq('amount_to_capture' => '500')
    end
  end
end
