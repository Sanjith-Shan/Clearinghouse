# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::App do
  include_context 'with the api app'

  let(:app_class) do
    pi = fixture('payment_intent')
    Class.new(described_class) do
      get('/v1/test_intent') { respond(pi) }
      post('/v1/test_capture') do
        respond({ 'id' => 'x', 'object' => 'echo', 'params' => versioned_params('payment_intents.capture').raw })
      end
    end
  end

  it 'renders at the latest version by default and says so' do
    get '/v1/test_intent'
    expect(last_response.headers['clearinghouse-version']).to eq('2026-09-01')
    expect(json_body).to eq(fixture('payment_intent'))
  end

  it 'renders at the version in the Clearinghouse-Version header' do
    get '/v1/test_intent', {}, { 'HTTP_CLEARINGHOUSE_VERSION' => '2026-01-01' }
    expect(last_response.headers['clearinghouse-version']).to eq('2026-01-01')
    expect(json_body).to include('amount_captured' => 2000, 'failure_code' => nil)
    expect(json_body['payment_method']).to include('object' => 'payment_method')
  end

  it 'rejects an unknown version rather than guessing' do
    get '/v1/test_intent', {}, { 'HTTP_CLEARINGHOUSE_VERSION' => '2026-02-30' }
    expect(last_response.status).to eq(400)
    expect(json_body['error']).to include('type' => 'invalid_request_error', 'code' => 'api_version_invalid')
    expect(json_body['error']['message']).to include('2026-01-01, 2026-03-01, 2026-06-01, 2026-09-01')
  end

  it 'applies expand[] from the query string' do
    get '/v1/test_intent?expand[]=payment_method'
    expect(json_body['payment_method']).to include('id' => 'pm_card_visa', 'object' => 'payment_method')
  end

  it 'turns a bad expand path into a parameter error' do
    get '/v1/test_intent?expand[]=status'
    expect(last_response.status).to eq(400)
    expect(json_body['error']).to include('param' => 'expand', 'code' => 'parameter_invalid',
                                          'message' => 'This property cannot be expanded (status).')
  end

  it 'logs the version the request was rendered at' do
    log = StringIO.new
    logged = Clearinghouse::Api::Dependencies.new(db: deps.db, clock: clock, log: log)
    Rack::MockRequest.new(Clearinghouse::Api::RequestLogger.new(app_class.new(logged), logged))
                     .get('/v1/test_intent', 'HTTP_CLEARINGHOUSE_VERSION' => '2026-06-01')
    expect(JSON.parse(log.string)['api_version']).to eq('2026-06-01')
  end

  context 'with a change that renamed a request parameter' do
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
      post '/v1/test_capture', 'amount=500', { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
                                               'HTTP_CLEARINGHOUSE_VERSION' => '2026-01-01' }
      expect(json_body['params']).to eq('amount_to_capture' => '500')
    end

    it 'leaves a current caller alone' do
      post '/v1/test_capture', 'amount_to_capture=500', { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
      expect(json_body['params']).to eq('amount_to_capture' => '500')
    end
  end
end
