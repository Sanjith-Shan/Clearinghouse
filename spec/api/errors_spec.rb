# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Errors do
  include_context 'with the api app'

  let(:errors) { described_class }
  let(:raisers) do
    e = described_class
    {
      'invalid' => -> { e::InvalidRequestError.missing_parameter('amount') },
      'not_found' => -> { e::NotFoundError.resource('payment_intent', 'pi_123') },
      'card' => lambda {
        e::CardError.new('Your card was declined.', code: 'card_declined', decline_code: 'insufficient_funds',
                                                    param: 'payment_method')
      },
      'reused' => -> { e::IdempotencyKeyReusedError.new('key-1') },
      'in_use' => -> { e::IdempotencyKeyInUseError.new('key-1') },
      'auth' => lambda {
        e::AuthenticationError.new('Invalid API Key provided: sk_test_****abcd', code: 'api_key_invalid')
      },
      'rate' => -> { e::RateLimitError.new },
      'risk' => -> { e::RiskError.new },
      'boom' => -> { raise ZeroDivisionError, 'secret internals: password=hunter2' }
    }
  end

  let(:log) { StringIO.new }
  let(:app_class) do
    table = raisers
    Class.new(Clearinghouse::Api::App) do
      %w[get post].each do |verb|
        send(verb, '/test/:kind') do |kind|
          raise table.fetch(kind).call
        end
      end
    end
  end

  def error_for(kind, verb: :get, headers: {})
    send(verb, "/test/#{kind}", {}, headers)
    json_body.fetch('error')
  end

  it 'renders an invalid_request_error as a 400 naming the param' do
    error = error_for('invalid')
    expect(last_response.status).to eq(400)
    expect(error).to eq('type' => 'invalid_request_error', 'code' => 'parameter_missing', 'decline_code' => nil,
                        'param' => 'amount', 'message' => 'Missing required param: amount.',
                        'doc_url' => "#{errors::DOC_BASE}#parameter_missing")
    expect(last_response.headers['clearinghouse-should-retry']).to eq('false')
  end

  it 'renders a missing resource as a 404 invalid_request_error' do
    error = error_for('not_found')
    expect(last_response.status).to eq(404)
    expect(error).to include('type' => 'invalid_request_error', 'code' => 'resource_missing', 'param' => 'id')
  end

  it 'renders a decline as a 402 card_error with its decline code' do
    error = error_for('card')
    expect(last_response.status).to eq(402)
    expect(error).to include('type' => 'card_error', 'code' => 'card_declined', 'decline_code' => 'insufficient_funds',
                             'param' => 'payment_method')
  end

  it 'renders a parameter mismatch on a reused key as a 400 idempotency_error that should not be retried' do
    error = error_for('reused', verb: :post)
    expect(last_response.status).to eq(400)
    expect(error).to include('type' => 'idempotency_error', 'code' => 'idempotency_key_reused')
    expect(last_response.headers['clearinghouse-should-retry']).to eq('false')
  end

  it 'renders a key still in flight as a 409 idempotency_error that should be retried' do
    error = error_for('in_use', verb: :post)
    expect(last_response.status).to eq(409)
    expect(error).to include('type' => 'idempotency_error', 'code' => 'idempotency_key_in_use')
    expect(last_response.headers['clearinghouse-should-retry']).to eq('true')
  end

  it 'renders an authentication_error as a 401 with a challenge' do
    error = error_for('auth')
    expect(last_response.status).to eq(401)
    expect(error).to include('type' => 'authentication_error', 'code' => 'api_key_invalid')
    expect(last_response.headers['www-authenticate']).to eq('Bearer realm="Clearinghouse"')
  end

  it 'renders a rate_limit_error as a 429 that should be retried' do
    error = error_for('rate')
    expect(last_response.status).to eq(429)
    expect(error).to include('type' => 'rate_limit_error', 'code' => 'rate_limit')
    expect(last_response.headers['clearinghouse-should-retry']).to eq('true')
  end

  it 'renders a RiskGate block as a 402 risk_error with code payment_blocked' do
    error = error_for('risk')
    expect(last_response.status).to eq(402)
    expect(error).to include('type' => 'risk_error', 'code' => 'payment_blocked', 'decline_code' => nil)
  end

  describe 'an unexpected exception' do
    it 'is a 500 api_error that names the request id and nothing else' do
      error = error_for('boom')
      request_id = last_response.headers['request-id']
      expect(last_response.status).to eq(500)
      expect(error).to eq('type' => 'api_error', 'code' => nil, 'decline_code' => nil, 'param' => nil,
                          'message' => "An unexpected error occurred while processing your request (#{request_id}).")
      expect(last_response.body).not_to include('hunter2', 'ZeroDivisionError')
    end

    it 'is logged with the request id so it can be found' do
      error_for('boom')
      entry = log.string.lines.map { |l| JSON.parse(l) }.find { |l| l['level'] == 'error' }
      expect(entry).to include('request_id' => last_response.headers['request-id'], 'exception' => 'ZeroDivisionError')
    end

    it 'may be retried when the request was a read' do
      error_for('boom')
      expect(last_response.headers['clearinghouse-should-retry']).to eq('true')
    end

    it 'may be retried when the POST carried an idempotency key, because the retry replays' do
      error_for('boom', verb: :post, headers: { 'HTTP_IDEMPOTENCY_KEY' => 'k1' })
      expect(last_response.headers['clearinghouse-should-retry']).to eq('true')
    end

    it 'says nothing about retrying a keyless POST, which may already have had its effect' do
      error_for('boom', verb: :post)
      expect(last_response.headers).not_to have_key('clearinghouse-should-retry')
    end
  end

  it 'renders an unknown route as a 404 in the same shape' do
    get '/nope'
    expect(last_response.status).to eq(404)
    expect(last_response.content_type).to eq('application/json')
    expect(json_body['error']).to include('type' => 'invalid_request_error', 'code' => 'url_invalid',
                                          'message' => 'Unrecognized request URL (GET: /nope).')
  end

  context 'with a merchant' do
    include_context 'with a merchant'

    it 'renders an unknown /v1 route as a 404 once authenticated' do
      get '/v1/nope', {}, auth
      expect(last_response.status).to eq(404)
      expect(json_body['error']).to include('code' => 'url_invalid')
    end
  end

  it 'omits doc_url when there is no code' do
    expect(errors::ApiError.new('req_x').to_h['error']).not_to have_key('doc_url')
  end

  it 'documents every code the error classes use' do
    doc = File.read(File.expand_path('../../docs/api-errors.md', __dir__))
    codes = raisers.except('boom').values.map { |r| r.call.code }
    codes += %w[parameter_unknown parameter_invalid url_invalid body_invalid api_key_missing admin_token_invalid
                api_version_invalid]
    codes.uniq.each { |code| expect(doc).to include("`#{code}`") }
  end
end
