# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::App do
  include_context 'with the api app'

  describe 'GET /healthz' do
    it 'reports ok after a database round trip' do
      get '/healthz'
      expect(last_response.status).to eq(200)
      expect(json_body).to eq('status' => 'ok', 'database' => 'ok')
      expect(last_response.content_type).to eq('application/json')
    end

    context 'when the database is unreachable' do
      let(:deps) do
        broken = Sequel.connect('postgres://nobody:wrong@127.0.0.1:1/none', test: false)
        Clearinghouse::Api::Dependencies.new(db: broken, clock: clock)
      end

      it 'answers 503' do
        get '/healthz'
        expect(last_response.status).to eq(503)
        expect(json_body['status']).to eq('unavailable')
      end
    end
  end

  describe 'request ids' do
    it 'puts a fresh req_ id on every response' do
      get '/healthz'
      first = last_response.headers['request-id']
      get '/healthz'
      expect(first).to match(/\Areq_[A-Za-z0-9]{24}\z/)
      expect(last_response.headers['request-id']).not_to eq(first)
    end

    it 'exposes the id to routes through the context' do
      seen = nil
      app_class = Class.new(described_class) do
        get('/ctx') do
          seen = ctx.request_id
          respond({})
        end
      end
      Rack::MockRequest.new(Clearinghouse::Api::RequestLogger.new(app_class.new(deps), deps)).get('/ctx').then do |res|
        expect(seen).to eq(res.headers['request-id'])
      end
    end
  end

  describe 'request logging' do
    let(:log) { StringIO.new }

    it 'writes one JSON line per request' do
      get '/healthz', {}, { 'HTTP_IDEMPOTENCY_KEY' => 'abc' }
      lines = log.string.lines
      expect(lines.size).to eq(1)
      entry = JSON.parse(lines.first)
      expect(entry).to include('method' => 'GET', 'path' => '/healthz', 'status' => 200, 'idempotency_key' => 'abc',
                               'request_id' => last_response.headers['request-id'],
                               'time' => '2026-09-01T12:00:00.000Z')
      expect(entry['duration_ms']).to be_a(Numeric)
    end

    it 'logs rejected requests as well' do
      get '/missing'
      expect(JSON.parse(log.string.lines.last)).to include('status' => 404, 'path' => '/missing')
    end
  end

  it 'is quiet when no log is configured' do
    expect { get '/healthz' }.not_to output.to_stdout
  end

  it 'does not honour _method overrides' do
    post '/healthz', '_method=GET', { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
    expect(last_response.status).to eq(404)
  end
end
