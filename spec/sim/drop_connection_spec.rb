# typed: false
# frozen_string_literal: true

require 'net/http'
require_relative 'sim_helper'

# The ambiguous case, over a real socket: the simulator commits and then hangs up.
# A plain Net::HTTP client must see the connection end with no response (not a 500),
# and the status query must then show the operation that was committed.
RSpec.describe AcquirerSim::App do
  describe 'dropping the connection after commit, over TCP' do
    let(:server) { SimServer.start }
    let(:now) { '2026-03-01T12:00:00Z' }
    let(:timeout_card) { { payment_method: 'pm_card_timeout', amount: 4_200, currency: 'usd', reference: 'pi_t' } }

    after { server.stop }

    def post(path, body, key)
      http = Net::HTTP.new('127.0.0.1', server.port)
      http.max_retries = 0
      http.read_timeout = 5
      request = Net::HTTP::Post.new(path, 'Content-Type' => 'application/json', 'Sim-Time' => now,
                                          'Idempotency-Key' => key)
      request.body = JSON.generate(body)
      http.request(request)
    end

    def get(path)
      Net::HTTP.start('127.0.0.1', server.port) { |http| http.get(path, 'Sim-Time' => now) }
    end

    it 'drops the connection on pm_card_timeout, and the status query shows the committed authorization' do
      expect { post('/authorize', timeout_card, 'pi_t:1') }
        .to(raise_error { |e| expect([EOFError, Errno::ECONNRESET, Errno::EPIPE]).to include(e.class) })

      status = get('/operations/pi_t:1')
      expect(status.code).to eq('200')
      expect(JSON.parse(status.body)).to include('type' => 'authorize', 'status' => 'approved', 'amount' => 4_200,
                                                 'idempotency_key' => 'pi_t:1', 'reference' => 'pi_t')
      expect(server.simulator.authorizations.size).to eq(1)
    end

    it 'answers a retry of the dropped key normally, with the same operation and no second charge' do
      expect { post('/authorize', timeout_card, 'pi_t:1') }.to raise_error(StandardError)
      retry_response = post('/authorize', timeout_card, 'pi_t:1')
      expect(retry_response.code).to eq('200')
      expect(retry_response['Idempotent-Replayed']).to eq('true')
      expect(JSON.parse(retry_response.body)).to eq(JSON.parse(get('/operations/pi_t:1').body))
      expect(server.simulator.authorizations.size).to eq(1)
    end

    it 'drops any operation after commit when drop_after_commit_rate is 1' do
      auth = JSON.parse(post('/authorize', timeout_card.merge(payment_method: 'pm_card_visa'), 'a1').body)
      server.simulator.configure('drop_after_commit_rate' => 1.0)

      expect { post('/capture', { acquirer_reference: auth['acquirer_reference'], amount: 4_200 }, 'c1') }
        .to(raise_error { |e| expect([EOFError, Errno::ECONNRESET, Errno::EPIPE]).to include(e.class) })
      expect(JSON.parse(get('/operations/c1').body)).to include('type' => 'capture', 'status' => 'succeeded')
      expect(server.simulator.authorizations.first.captured).to eq(4_200)
    end

    it 'keeps serving other connections after a drop' do
      expect { post('/authorize', timeout_card, 'x') }.to raise_error(StandardError)
      expect(get('/health').code).to eq('200')
    end
  end
end
