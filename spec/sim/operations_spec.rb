# typed: false
# frozen_string_literal: true

require 'securerandom'
require_relative 'sim_helper'

RSpec.describe AcquirerSim::App do
  include SimHelper

  describe 'POST /authorize' do
    it 'approves the approving test tokens and records Sim-Time as created_at' do
      %w[pm_card_visa pm_card_mastercard].each do |pm|
        op = authorize!(payment_method: pm, key: "k-#{pm}")
        expect(op).to include('type' => 'authorize', 'status' => 'approved', 'decline_code' => nil,
                              'amount' => 10_000, 'currency' => 'usd', 'reference' => 'pi_1',
                              'idempotency_key' => "k-#{pm}", 'created_at' => '2026-03-01T12:00:00.000000Z')
        expect(op['id']).to match(/\Aop_\h{24}\z/)
        expect(op['acquirer_reference']).to match(/\Aacq_\h{24}\z/)
      end
    end

    it 'declines with the code each declining token names' do
      {
        'pm_card_chargeDeclined' => 'generic_decline',
        'pm_card_insufficientFunds' => 'insufficient_funds',
        'pm_card_expired' => 'expired_card'
      }.each do |pm, code|
        op = authorize!(payment_method: pm)
        expect(op).to include('status' => 'declined', 'decline_code' => code)
      end
    end

    it 'captures in the same call when capture is true' do
      op = authorize!(capture: true)
      auth = simulator.authorizations.find { |a| a.acquirer_reference == op['acquirer_reference'] }
      expect(auth.captured).to eq(10_000)
      expect(auth.captured_at).to eq(SimHelper::T0)
    end

    it 'normalizes the currency and accepts zero- and three-decimal currencies' do
      expect(authorize!(currency: 'JPY', amount: 500)['currency']).to eq('jpy')
      expect(authorize!(currency: 'kwd', amount: 1_234)['currency']).to eq('kwd')
    end

    it 'refuses malformed requests with a 400 naming the field, and records nothing' do
      cases = {
        { payment_method: 'pm_card_nope', amount: 100, currency: 'usd' } => 'payment_method',
        { payment_method: 'pm_card_visa', amount: 0, currency: 'usd' } => 'amount',
        { payment_method: 'pm_card_visa', amount: 1.5, currency: 'usd' } => 'amount',
        { payment_method: 'pm_card_visa', amount: '100', currency: 'usd' } => 'amount',
        { payment_method: 'pm_card_visa', amount: 100, currency: 'xyz' } => 'currency',
        { payment_method: 'pm_card_visa', amount: 100, currency: 'usd', capture: 'yes' } => 'capture',
        { amount: 100, currency: 'usd' } => 'payment_method'
      }
      cases.each do |body, param|
        response = post_json('/authorize', body)
        expect(response.status).to eq(400), "#{body} gave #{response.status}"
        expect(json_body(response)).to include('error' => 'invalid_request', 'param' => param)
      end
      expect(simulator.operations).to be_empty
      expect(simulator.authorizations).to be_empty
    end

    it 'refuses a body that is not a JSON object' do
      expect(post_json('/authorize', 'not json').status).to eq(400)
      expect(post_json('/authorize', '[1,2]').status).to eq(400)
    end

    it 'requires Sim-Time and refuses a malformed one' do
      body = { payment_method: 'pm_card_visa', amount: 100, currency: 'usd' }
      expect(json_body(post_json('/authorize', body, at: nil))['error']).to eq('sim_time_required')
      bad = post_json('/authorize', body, headers: { 'Sim-Time' => 'yesterday' })
      expect(json_body(bad)['error']).to eq('sim_time_invalid')
    end

    it 'requires an Idempotency-Key' do
      response = call(:post, '/authorize', { payment_method: 'pm_card_visa', amount: 100, currency: 'usd' })
      expect(response.status).to eq(400)
      expect(json_body(response)['error']).to eq('idempotency_key_required')
    end
  end

  describe 'capture, void and refund' do
    let(:auth) { authorize!(amount: 10_000) }
    let(:ref) { auth['acquirer_reference'] }

    def follow(type, body = {})
      json_body(post_json("/#{type}", { acquirer_reference: ref }.merge(body)))
    end

    it 'captures part of an authorization and releases the rest' do
      expect(follow('capture', amount: 6_000)).to include('type' => 'capture', 'status' => 'succeeded',
                                                          'amount' => 6_000, 'currency' => 'usd',
                                                          'reference' => 'pi_1', 'acquirer_reference' => ref)
      expect(follow('capture', amount: 1_000)).to include('status' => 'failed', 'decline_code' => 'already_captured')
    end

    it 'refuses to capture more than was authorized' do
      expect(follow('capture', amount: 10_001)).to include('status' => 'failed',
                                                           'decline_code' => 'amount_exceeds_authorized')
      expect(follow('capture', amount: 10_000)['status']).to eq('succeeded')
    end

    it 'refuses a capture after a void, and a void after a capture' do
      expect(follow('void')).to include('status' => 'succeeded', 'amount' => 10_000)
      expect(follow('capture', amount: 100)).to include('decline_code' => 'authorization_voided')

      other = authorize!['acquirer_reference']
      post_json('/capture', { acquirer_reference: other, amount: 100 })
      expect(json_body(post_json('/void', { acquirer_reference: other }))['decline_code']).to eq('already_captured')
    end

    it 'allows several partial refunds but never more in total than was captured' do
      follow('capture', amount: 8_000)
      expect(follow('refund', amount: 5_000)['status']).to eq('succeeded')
      expect(follow('refund', amount: 3_000)['status']).to eq('succeeded')
      expect(follow('refund', amount: 1)).to include('status' => 'failed', 'decline_code' => 'amount_exceeds_captured')
      expect(simulator.authorizations.first.refunded).to eq(8_000)
    end

    it 'refuses a refund before any capture' do
      expect(follow('refund', amount: 1)['decline_code']).to eq('amount_exceeds_captured')
    end

    it 'fails every follow-on against a declined authorization' do
      declined = authorize!(payment_method: 'pm_card_expired')['acquirer_reference']
      %w[capture void refund].each do |type|
        op = json_body(post_json("/#{type}", { acquirer_reference: declined, amount: 100 }))
        expect(op['decline_code']).to eq('authorization_declined')
      end
    end

    it 'fails an unknown reference as a recorded operation' do
      op = json_body(post_json('/capture', { acquirer_reference: 'acq_nope', amount: 100 }, key: 'cap-unknown'))
      expect(op).to include('status' => 'failed', 'decline_code' => 'unknown_reference', 'currency' => nil)
      expect(call(:get, '/operations/cap-unknown').status).to eq(200)
    end

    it 'fails a follow-on whose currency disagrees with the authorization' do
      expect(follow('capture', amount: 100, currency: 'eur')['decline_code']).to eq('currency_mismatch')
      expect(follow('capture', amount: 100, currency: 'usd')['status']).to eq('succeeded')
    end
  end

  describe 'idempotency' do
    let(:body) { { payment_method: 'pm_card_visa', amount: 2_500, currency: 'usd', capture: true, reference: 'pi_9' } }

    it 'replays the stored operation byte for byte and does not charge twice' do
      first = post_json('/authorize', body, key: 'same')
      second = post_json('/authorize', body, key: 'same', at: SimHelper::T0 + 3_600)
      expect(second.body).to eq(first.body)
      expect(first.headers['Idempotent-Replayed']).to eq('false')
      expect(second.headers['Idempotent-Replayed']).to eq('true')
      expect(simulator.authorizations.size).to eq(1)
    end

    it 'treats the same fields in a different order as the same request' do
      post_json('/authorize', body, key: 'same')
      reordered = body.to_a.reverse.to_h
      expect(post_json('/authorize', reordered, key: 'same').headers['Idempotent-Replayed']).to eq('true')
    end

    it 'refuses the same key with a different body, and changes nothing' do
      post_json('/authorize', body, key: 'same')
      response = post_json('/authorize', body.merge(amount: 2_501), key: 'same')
      expect(response.status).to eq(409)
      expect(json_body(response)['error']).to eq('idempotency_key_mismatch')
      expect(simulator.authorizations.map(&:amount)).to eq([2_500])
    end

    it 'refuses the same key reused for a different operation type' do
      op = json_body(post_json('/authorize', body, key: 'same'))
      response = post_json('/refund', { acquirer_reference: op['acquirer_reference'], amount: 1 }, key: 'same')
      expect(response.status).to eq(409)
      expect(simulator.authorizations.first.refunded).to eq(0)
    end

    it 'replays a failed operation even after the state that failed it has changed' do
      ref = authorize!['acquirer_reference']
      refund = { acquirer_reference: ref, amount: 100 }
      expect(json_body(post_json('/refund', refund, key: 'r1'))['status']).to eq('failed')
      post_json('/capture', { acquirer_reference: ref, amount: 1_000 })
      expect(json_body(post_json('/refund', refund, key: 'r1'))['status']).to eq('failed')
      expect(json_body(post_json('/refund', refund, key: 'r2'))['status']).to eq('succeeded')
    end

    it 'does not burn a key on a malformed request' do
      expect(post_json('/authorize', body.merge(amount: -1), key: 'k').status).to eq(400)
      expect(json_body(post_json('/authorize', body, key: 'k'))['status']).to eq('approved')
    end

    it 'commits exactly once when many threads race on one key' do
      responses = Array.new(32) do
        Thread.new { simulator.submit('authorize', 'race', JSON.parse(JSON.generate(body)), SimHelper::T0) }
      end.map(&:value)
      expect(responses.map { |r| r.operation.id }.uniq.size).to eq(1)
      expect(responses.count { |r| !r.replayed }).to eq(1)
      expect(simulator.authorizations.size).to eq(1)
    end

    it 'derives references from the key, so they survive a reset and differ across keys' do
      a = authorize!(key: 'k1')
      simulator.reset!
      expect(authorize!(key: 'k1')['acquirer_reference']).to eq(a['acquirer_reference'])
      expect(authorize!(key: 'k2')['acquirer_reference']).not_to eq(a['acquirer_reference'])
    end
  end

  describe 'GET /operations/:key' do
    it 'returns the committed operation for a key, and 404 for one never seen' do
      op = authorize!(key: 'pi_1:attempt:1')
      response = call(:get, '/operations/pi_1:attempt:1')
      expect(response.status).to eq(200)
      expect(json_body(response)).to eq(op)
      missing = call(:get, '/operations/pi_1:attempt:2')
      expect(missing.status).to eq(404)
      expect(json_body(missing)['error']).to eq('not_found')
    end
  end

  describe 'admin' do
    it 'counts authorizations that captured money per reference' do
      authorize!(reference: 'pi_a', capture: true)
      authorize!(reference: 'pi_a', capture: true)
      authorize!(reference: 'pi_b', capture: false)
      authorize!(reference: 'pi_c', payment_method: 'pm_card_chargeDeclined')
      charges = json_body(call(:get, '/admin/operations'))['charges_by_reference']
      expect(charges['pi_a']).to include('authorizations' => 2, 'captured' => 2, 'captured_amount' => 20_000)
      expect(charges['pi_b']).to include('approved' => 1, 'captured' => 0)
      expect(charges['pi_c']).to include('authorizations' => 1, 'approved' => 0)
    end

    it 'filters by reference' do
      authorize!(reference: 'pi_a')
      authorize!(reference: 'pi_b')
      body = json_body(call(:get, '/admin/operations?reference=pi_b'))
      expect(body['operations'].map { |o| o['reference'] }).to eq(['pi_b'])
      expect(body['authorizations'].size).to eq(1)
    end

    it 'forgets everything on reset' do
      authorize!(key: 'k')
      call(:post, '/admin/reset')
      expect(call(:get, '/operations/k').status).to eq(404)
      expect(simulator.authorizations).to be_empty
    end

    it 'answers 404 as JSON for an unknown route' do
      response = call(:get, '/nope')
      expect(response.status).to eq(404)
      expect(json_body(response)['error']).to eq('not_found')
    end
  end
end
