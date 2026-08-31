# typed: false
# frozen_string_literal: true

require 'stringio'
require_relative 'sim_helper'

RSpec.describe AcquirerSim::App do
  describe 'misbehaviour on command' do
    include SimHelper

    let(:visa) { { payment_method: 'pm_card_visa', amount: 1_000, currency: 'usd' } }

    it 'answers 503 without committing anything when error_rate is 1' do
      simulator.configure('error_rate' => 1.0)
      response = post_json('/authorize', visa, key: 'k')
      expect(response.status).to eq(503)
      expect(json_body(response)['error']).to eq('service_unavailable')
      simulator.configure('error_rate' => 0.0)
      expect(call(:get, '/operations/k').status).to eq(404)
      expect(simulator.authorizations).to be_empty
    end

    it 'applies error_rate to the status query too' do
      simulator.configure('error_rate' => 1.0)
      expect(call(:get, '/operations/anything').status).to eq(503)
    end

    def raw_post(path, body, key, extra_env = {})
      post(path, JSON.generate(body), { 'HTTP_SIM_TIME' => SimHelper::T0.iso8601, 'HTTP_IDEMPOTENCY_KEY' => key,
                                        'CONTENT_TYPE' => 'application/json' }.merge(extra_env))
      last_response
    end

    it 'commits, then takes the socket and closes it without writing a byte, for pm_card_timeout' do
      socket = StringIO.new
      raw_post('/authorize', visa.merge(payment_method: 'pm_card_timeout'), 'k',
               'rack.hijack?' => true, 'rack.hijack' => -> { socket })
      expect(socket).to be_closed
      expect(socket.string).to be_empty
      expect(simulator.operation('k')&.status).to eq('approved')
    end

    it 'still commits but answers 500 on a server that cannot hijack, rather than a normal response' do
      expect(raw_post('/authorize', visa.merge(payment_method: 'pm_card_timeout'), 'k').status).to eq(500)
      expect(simulator.operation('k')&.status).to eq('approved')
    end

    it 'answers a replay of a dropped key instead of dropping again' do
      simulator.configure('drop_after_commit_rate' => 1.0)
      post_json('/authorize', visa, key: 'k')
      replay = post_json('/authorize', visa, key: 'k')
      expect(replay.status).to eq(200)
      expect(replay.headers['Idempotent-Replayed']).to eq('true')
    end

    it 'reads a JSON body even when the client labels it as a form' do
      response = raw_post('/authorize', visa, 'k', 'CONTENT_TYPE' => 'application/x-www-form-urlencoded')
      expect(response.status).to eq(200)
      expect(json_body(response)['status']).to eq('approved')
    end

    describe 'POST /admin/config' do
      it 'merges the fields given and returns the whole config' do
        body = json_body(call(:post, '/admin/config', { seed: 9, latency_ms: { p50: 5, p99: 50 }, error_rate: 0.1 }))
        expect(body).to include('seed' => 9, 'latency_ms' => { 'p50' => 5.0, 'p99' => 50.0 }, 'error_rate' => 0.1,
                                'drop_after_commit_rate' => 0.0)
        expect(json_body(call(:get, '/admin/config'))['seed']).to eq(9)
      end

      it 'refuses nonsense with a 400 and keeps the old config' do
        [{ error_rate: 1.5 }, { error_rate: -0.1 }, { latency_ms: { p50: 50, p99: 5 } }, { latency_ms: 5 },
         { seed: -1 }, { seed: 'x' }, { latency_ms: { p50: 0, p99: 5 } }, { bogus: 1 }].each do |bad|
          response = call(:post, '/admin/config', bad)
          expect(response.status).to eq(400), "#{bad} gave #{response.status}"
        end
        expect(simulator.config.serialize).to eq(AcquirerSim::Config.new.serialize)
      end

      it 'goes back to defaults on reset' do
        call(:post, '/admin/config', { error_rate: 1.0 })
        call(:post, '/admin/reset')
        expect(simulator.config.error_rate).to eq(0.0)
      end
    end
  end
end
