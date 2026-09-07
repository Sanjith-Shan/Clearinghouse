# typed: false
# frozen_string_literal: true

require 'open3'
require_relative 'client_helper'

# Against a real socket that fails on command. Every retry spec checks three things:
# how many attempts reached the server, that they all carried the same
# Idempotency-Key, and how long the client asked to sleep between them.
RSpec.describe ClearinghouseClient::Client do
  let(:servers) { [] }
  let(:sleeper) { RecordingSleeper.new }
  let(:options) { {} }

  after { servers.each(&:stop) }

  def serve(*script)
    ScriptedApiServer.new(*script).tap { |server| servers << server }
  end

  def client_for(server, **overrides)
    described_class.new(api_key: 'sk_test_client', base_url: server.url, sleeper: sleeper.to_proc,
                        rng: FixedRandom.new(0.5), read_timeout: 2, **options, **overrides)
  end

  def create(client, **options)
    client.request(:post, '/v1/payment_intents', params: { amount: 2000, currency: 'usd' }, **options)
  end

  describe 'a mutating call' do
    it 'sends a fresh UUID v4 Idempotency-Key, JSON, the key and the version' do
      server = serve(ok)
      response = create(client_for(server, api_version: '2026-03-01'))

      request = server.requests.fetch(0)
      expect(request.request_line).to eq('POST /v1/payment_intents HTTP/1.1')
      expect(request.headers['idempotency-key']).to match(ClientSpecHelpers::UUID_V4)
      expect(request.headers['authorization']).to eq('Bearer sk_test_client')
      expect(request.headers['clearinghouse-version']).to eq('2026-03-01')
      expect(request.headers['content-type']).to eq('application/json')
      expect(JSON.parse(request.body)).to eq('amount' => 2000, 'currency' => 'usd')
      expect(response.data).to eq('id' => 'pi_1', 'object' => 'payment_intent')
      expect([response.request_id, response.attempts, response.idempotent_replayed?]).to eq(['req_ok', 1, false])
    end

    it 'uses a different key for each logical call' do
      server = serve(ok)
      client = client_for(server)
      2.times { create(client) }
      expect(server.idempotency_keys.uniq.length).to eq(2)
    end

    it "uses the caller's key when given one" do
      server = serve(:drop, ok)
      create(client_for(server), idempotency_key: 'order-6735-charge')
      expect(server.idempotency_keys).to eq(%w[order-6735-charge order-6735-charge])
    end

    it 'lets one call override the API version' do
      server = serve(ok)
      create(client_for(server, api_version: '2026-03-01'), api_version: '2026-01-01')
      expect(server.requests.fetch(0).headers['clearinghouse-version']).to eq('2026-01-01')
    end
  end

  describe 'retries' do
    it 'retries dropped connections with the same key and a doubling backoff' do
      server = serve(:drop, :drop, ok)
      response = create(client_for(server))

      expect(server.attempts).to eq(3)
      expect(server.idempotency_keys.uniq.length).to eq(1)
      expect(sleeper.calls).to eq([0.25, 0.5])
      expect(response.attempts).to eq(3)
    end

    it 'raises APIConnectionError once retries run out, having used the same key throughout' do
      server = serve(:drop)
      expect { create(client_for(server)) }.to raise_error(ClearinghouseClient::APIConnectionError) { |e|
        expect(e.maybe_processed?).to be(true)
        expect(e.message).to include('may or may not have been processed')
      }
      expect(server.attempts).to eq(3)
      expect(server.idempotency_keys.uniq.length).to eq(1)
    end

    it 'retries a read timeout, where the first attempt may still be running' do
      server = serve([:hang, 1], ok)
      create(client_for(server, read_timeout: 0.2))
      expect(server.attempts).to eq(2)
      expect(server.idempotency_keys.uniq.length).to eq(1)
    end

    it 'retries a refused connection and says nothing was sent' do
      port = TCPServer.new('127.0.0.1', 0).then { |s| s.addr[1].tap { s.close } }
      client = described_class.new(api_key: 'sk_test_client', base_url: "http://127.0.0.1:#{port}",
                                   sleeper: sleeper.to_proc, rng: FixedRandom.new(0.5))
      expect { create(client) }.to raise_error(ClearinghouseClient::APIConnectionError) { |e|
        expect(e.maybe_processed?).to be(false)
      }
      expect(sleeper.calls.length).to eq(2)
    end

    it 'retries a 409 in-flight conflict and reports the replayed result' do
      server = serve(error(409, 'idempotency_error', { 'Clearinghouse-Should-Retry' => 'true' },
                           code: 'idempotency_key_in_use'),
                     ok({ 'id' => 'pi_1' }, 'Idempotent-Replayed' => 'true'))
      response = create(client_for(server))
      expect(server.attempts).to eq(2)
      expect(server.idempotency_keys.uniq.length).to eq(1)
      expect(response.idempotent_replayed?).to be(true)
    end

    it 'retries a 500 when the server gives no verdict' do
      server = serve(error(500, 'api_error'), ok)
      create(client_for(server))
      expect(server.attempts).to eq(2)
    end

    it 'does not retry a 500 the server says not to retry' do
      server = serve(error(500, 'api_error', { 'Clearinghouse-Should-Retry' => 'false' }), ok)
      expect { create(client_for(server)) }.to raise_error(ClearinghouseClient::APIError) { |e|
        expect([e.http_status, e.request_id]).to eq([500, 'req_500'])
      }
      expect(server.attempts).to eq(1)
      expect(sleeper.calls).to be_empty
    end

    it 'never retries a 400' do
      server = serve(error(400, 'invalid_request_error', code: 'parameter_missing', param: 'amount'), ok)
      expect { create(client_for(server)) }.to raise_error(ClearinghouseClient::InvalidRequestError) { |e|
        expect([e.param, e.code, e.http_status]).to eq(%w[amount parameter_missing] + [400])
      }
      expect(server.attempts).to eq(1)
      expect(sleeper.calls).to be_empty
    end

    it 'retries a 4xx the server says is retryable' do
      server = serve(error(400, 'invalid_request_error', { 'Clearinghouse-Should-Retry' => 'true' }), ok)
      create(client_for(server))
      expect(server.attempts).to eq(2)
    end

    it 'waits at least as long as Retry-After on a 429' do
      server = serve(error(429, 'rate_limit_error', { 'Retry-After' => '3' }), ok)
      create(client_for(server))
      expect(sleeper.calls).to eq([3.0])
    end

    it 'raises the last error when a 429 asks for a wait longer than the client will do' do
      server = serve(error(429, 'rate_limit_error', { 'Retry-After' => '600' }), ok)
      expect { create(client_for(server)) }.to raise_error(ClearinghouseClient::RateLimitError)
      expect(server.attempts).to eq(1)
    end

    it 'caps the backoff' do
      server = serve(error(503, 'api_error'))
      client = client_for(server, max_network_retries: 6, rng: FixedRandom.new(1.0))
      expect { create(client) }.to raise_error(ClearinghouseClient::APIError)
      expect(server.attempts).to eq(7)
      expect(sleeper.calls).to eq([0.5, 1.0, 2.0, 4.0, 8.0, 8.0])
    end

    it 'makes exactly one attempt with retries off, even for GET and DELETE' do
      # Net::HTTP retries idempotent verbs once by itself unless told not to.
      %i[get delete].each do |verb|
        server = serve(:drop)
        client = client_for(server, max_network_retries: 0)
        expect { client.request(verb, '/v1/webhook_endpoints/we_1') }
          .to raise_error(ClearinghouseClient::APIConnectionError)
        expect(server.attempts).to eq(1)
      end
    end
  end

  describe 'reads' do
    it 'sends no Idempotency-Key and puts params in a bracketed query string, leaving out nils' do
      server = serve(ok)
      client_for(server).request(:get, '/v1/payment_intents',
                                 params: { limit: 3, expand: ['data.payment_method'], created: { gte: 5 },
                                           starting_after: nil })
      request = server.requests.fetch(0)
      expect(request.headers).not_to have_key('idempotency-key')
      expect(URI.decode_www_form_component(request.request_line))
        .to eq('GET /v1/payment_intents?limit=3&expand[]=data.payment_method&created[gte]=5 HTTP/1.1')
    end

    it 'retries a dropped GET without any key' do
      server = serve(:drop, ok)
      client_for(server).request(:get, '/v1/balance')
      expect(server.idempotency_keys).to eq([nil, nil])
    end

    it 'refuses an Idempotency-Key on a GET' do
      client = client_for(serve(ok))
      expect { client.request(:get, '/v1/balance', idempotency_key: 'k') }.to raise_error(ArgumentError)
    end

    it 'gives DELETE a key like any other mutation' do
      server = serve(ok({ 'id' => 'we_1', 'deleted' => true }))
      client_for(server).request(:delete, '/v1/webhook_endpoints/we_1')
      expect(server.idempotency_keys.fetch(0)).to match(ClientSpecHelpers::UUID_V4)
    end
  end

  describe 'typed errors' do
    {
      'card_error' => ClearinghouseClient::CardError,
      'invalid_request_error' => ClearinghouseClient::InvalidRequestError,
      'idempotency_error' => ClearinghouseClient::IdempotencyError,
      'authentication_error' => ClearinghouseClient::AuthenticationError,
      'rate_limit_error' => ClearinghouseClient::RateLimitError,
      'risk_error' => ClearinghouseClient::RiskError,
      'api_error' => ClearinghouseClient::APIError
    }.each do |type, klass|
      it "maps #{type} to #{klass.name.split('::').last} with status, request id and the raw error" do
        server = serve(error(402, type, { 'Clearinghouse-Should-Retry' => 'false' }, code: 'some_code'))
        expect { create(client_for(server)) }.to raise_error(klass) { |e|
          expect([e.http_status, e.request_id, e.code]).to eq([402, 'req_402', 'some_code'])
          expect(e.error).to include('type' => type, 'message' => 'nope')
          expect(e.message).to eq('(Status 402) (Request req_402) nope')
        }
      end
    end

    it 'carries the decline code on a CardError' do
      server = serve(error(402, 'card_error', code: 'card_declined', decline_code: 'insufficient_funds'))
      expect { create(client_for(server)) }.to raise_error(ClearinghouseClient::CardError) { |e|
        expect(e.decline_code).to eq('insufficient_funds')
      }
    end

    it 'falls back on the status for a body that is not an API error' do
      server = serve([401, {}, '<html>nope</html>'], [502, {}, '<html>bad gateway</html>'])
      client = client_for(server, max_network_retries: 0)
      expect { create(client) }.to raise_error(ClearinghouseClient::AuthenticationError, /Unexpected HTTP 401/)
      expect { create(client) }.to raise_error(ClearinghouseClient::APIError) { |e|
        expect([e.http_status, e.error]).to eq([502, {}])
      }
    end

    it 'raises APIError for a success response that is not a JSON object' do
      server = serve([200, {}, '[1,2]'])
      response = create(client_for(server))
      expect { response.data }.to raise_error(ClearinghouseClient::APIError, /JSON object/)
    end
  end

  describe 'construction' do
    it 'rejects an empty key, a non-HTTP URL and an unknown method' do
      expect { described_class.new(api_key: ' ') }.to raise_error(ArgumentError, /api_key/)
      expect { described_class.new(api_key: 'sk', base_url: 'ftp://x') }.to raise_error(ArgumentError, /http/)
      expect { described_class.new(api_key: 'sk').request(:patch, '/v1/x') }.to raise_error(ArgumentError)
    end

    it 'keeps a path prefix in the base URL' do
      server = serve(ok)
      described_class.new(api_key: 'sk', base_url: "#{server.url}/api/").request(:get, '/v1/balance')
      expect(server.requests.fetch(0).request_line).to eq('GET /api/v1/balance HTTP/1.1')
    end

    it 'loads with the standard library alone, without RubyGems or sorbet-runtime' do
      lib = File.expand_path('../../../clients/ruby/lib', __dir__)
      script = 'require "clearinghouse_client"; ' \
               'ClearinghouseClient::Client.new(api_key: "sk_test_x"); ' \
               'print defined?(Gem).inspect, " ", $LOADED_FEATURES.grep(/sorbet-runtime/).length'
      output, status = Open3.capture2e({ 'RUBYOPT' => nil, 'BUNDLE_GEMFILE' => nil }, RbConfig.ruby,
                                       '--disable-gems', '-I', lib, '-e', script)
      expect(status).to be_success, output
      expect(output).to eq('nil 0')
    end
  end
end
