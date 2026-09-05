# typed: false
# frozen_string_literal: true

require 'securerandom'
require_relative 'sim_helper'

RSpec.describe AcquirerSim::App do
  include SimHelper

  let(:day) { 86_400 }

  def poll(at:, after: nil, limit: nil)
    query = { after: after, limit: limit }.compact.map { |k, v| "#{k}=#{v}" }.join('&')
    json_body(call(:get, "/notifications?#{query}", at: at))
  end

  def types(page)
    page['data'].map { |n| n['type'] }
  end

  describe 'disputes' do
    it 'opens a fraudulent dispute dispute_after_days after an immediate capture' do
      op = authorize!(payment_method: 'pm_card_disputeFraudulent', capture: true, amount: 7_700)
      expect(poll(at: SimHelper::T0 + (7 * day) - 1)['data']).to be_empty

      page = poll(at: SimHelper::T0 + (7 * day))
      expect(types(page)).to eq(['dispute.opened'])
      notification = page['data'].first
      expect(notification['created_at']).to eq((SimHelper::T0 + (7 * day)).iso8601(6))
      expect(notification['data']).to include('acquirer_reference' => op['acquirer_reference'], 'amount' => 7_700,
                                              'currency' => 'usd', 'reason' => 'fraudulent')
      expect(notification['data']['dispute_id']).to match(/\Adsp_\h{24}\z/)
    end

    it 'counts the delay from a later manual capture, for the captured amount, with the configured delay' do
      simulator.configure('dispute_after_days' => 3)
      op = authorize!(payment_method: 'pm_card_disputeFraudulent', amount: 9_000)
      expect(poll(at: SimHelper::T0 + (30 * day))['data']).to be_empty # never captured, never disputed

      post_json('/capture', { acquirer_reference: op['acquirer_reference'], amount: 5_000 }, at: SimHelper::T0 + day)
      expect(poll(at: SimHelper::T0 + (4 * day) - 1)['data']).to be_empty
      expect(poll(at: SimHelper::T0 + (4 * day))['data'].first['data']['amount']).to eq(5_000)
    end

    it 'allows refunds before the dispute opens and refuses them after' do
      ref = authorize!(payment_method: 'pm_card_disputeFraudulent', capture: true)['acquirer_reference']
      early = post_json('/refund', { acquirer_reference: ref, amount: 100 }, at: SimHelper::T0 + day)
      expect(json_body(early)['status']).to eq('succeeded')
      late = post_json('/refund', { acquirer_reference: ref, amount: 100 }, at: SimHelper::T0 + (7 * day))
      expect(json_body(late)).to include('status' => 'failed', 'decline_code' => 'charge_disputed')
    end

    it 'never disputes an ordinary card' do
      authorize!(capture: true)
      expect(poll(at: SimHelper::T0 + (365 * day))['data']).to be_empty
    end

    describe 'POST /admin/disputes/:id/resolve' do
      let(:dispute_id) do
        authorize!(payment_method: 'pm_card_disputeFraudulent', capture: true)
        simulator.disputes.first.id
      end
      let(:opened) { SimHelper::T0 + (7 * day) }

      def resolve(outcome, at:, id: dispute_id)
        call(:post, "/admin/disputes/#{id}/resolve", { outcome: outcome }, at: at)
      end

      it 'closes the dispute and makes dispute.closed visible at that Sim-Time' do
        response = resolve('won', at: opened + day)
        expect(response.status).to eq(200)
        expect(json_body(response)).to include('type' => 'dispute.closed')
        expect(json_body(response)['data']).to include('dispute_id' => dispute_id, 'outcome' => 'won')
        expect(types(poll(at: opened + day))).to eq(['dispute.opened', 'dispute.closed'])
        expect(simulator.disputes.first).to have_attributes(outcome: 'won', closed_at: opened + day)
      end

      it 'refuses to resolve before the dispute opens, twice, an unknown id, or a made-up outcome' do
        expect(json_body(resolve('won', at: opened - 1))['error']).to eq('dispute_not_open')
        expect(resolve('won', id: 'dsp_nope', at: opened).status).to eq(404)
        expect(resolve('maybe', at: opened).status).to eq(400)
        expect(resolve('lost', at: opened).status).to eq(200)
        second = resolve('won', at: opened + day)
        expect(second.status).to eq(409)
        expect(json_body(second)['error']).to eq('dispute_already_closed')
      end

      it 'requires Sim-Time' do
        expect(json_body(resolve('won', at: nil))['error']).to eq('sim_time_required')
      end
    end
  end

  describe 'payouts' do
    def payout(amount, key: "po-#{SecureRandom.hex(4)}", at: SimHelper::T0)
      post_json('/payouts', { reference: 'po_1', merchant_id: 'acct_1', amount: amount, currency: 'usd' },
                key: key, at: at)
    end

    it 'accepts a payout and reports it paid one simulated day later' do
      op = json_body(payout(5_000))
      expect(op).to include('type' => 'payout', 'status' => 'succeeded', 'reference' => 'po_1', 'amount' => 5_000)
      expect(op['acquirer_reference']).to match(/\Aacqpo_\h{24}\z/)
      expect(poll(at: SimHelper::T0 + day - 1)['data']).to be_empty

      paid = poll(at: SimHelper::T0 + day)['data']
      expect(paid.map { |n| [n['type'], n['data']['reference']] }).to eq([%w[payout.paid po_1]])
    end

    it 'fails a payout whose amount ends in 13, with account_closed' do
      payout(1_013)
      failed = poll(at: SimHelper::T0 + day)['data'].first
      expect(failed).to include('type' => 'payout.failed')
      expect(failed['data']).to include('reference' => 'po_1', 'failure_code' => 'account_closed')
      expect(AcquirerSim::Simulator.payout_fails?(113)).to be(true)
      expect(AcquirerSim::Simulator.payout_fails?(1_310)).to be(false)
    end

    it 'does not schedule a second notification when the payout is replayed' do
      2.times { payout(5_000, key: 'po-same') }
      expect(poll(at: SimHelper::T0 + day)['data'].size).to eq(1)
      expect(simulator.payouts.size).to eq(1)
    end

    it 'lists disputes and payouts in /admin/operations' do
      payout(1_013)
      authorize!(payment_method: 'pm_card_disputeFraudulent', capture: true)
      body = json_body(call(:get, '/admin/operations'))
      expect(body['payouts'].first).to include('reference' => 'po_1', 'outcome' => 'failed',
                                               'failure_code' => 'account_closed')
      expect(body['disputes'].first).to include('reason' => 'fraudulent', 'amount' => 10_000, 'outcome' => nil)
    end

    it 'validates the payout body' do
      bad = post_json('/payouts', { reference: 'po_1', amount: 5_000, currency: 'usd' })
      expect(json_body(bad)['param']).to eq('merchant_id')
    end
  end

  describe 'GET /notifications cursor' do
    it 'pages with limit and next_cursor, and returns nothing new past the end' do
      3.times { |i| post_json('/payouts', { reference: "po_#{i}", merchant_id: 'm', amount: 100, currency: 'usd' }) }
      later = SimHelper::T0 + day
      first = poll(at: later, limit: 2)
      expect(first['data'].map { |n| n['data']['reference'] }).to eq(%w[po_0 po_1])
      second = poll(at: later, after: first['next_cursor'])
      expect(second['data'].map { |n| n['data']['reference'] }).to eq(['po_2'])
      third = poll(at: later, after: second['next_cursor'])
      expect(third).to eq('data' => [], 'next_cursor' => second['next_cursor'])
    end

    it 'orders a newly visible batch by due time, not by creation order' do
      post_json('/payouts', { reference: 'late', merchant_id: 'm', amount: 100, currency: 'usd' },
                at: SimHelper::T0 + 3_600)
      post_json('/payouts', { reference: 'early', merchant_id: 'm', amount: 100, currency: 'usd' })
      refs = poll(at: SimHelper::T0 + (2 * day))['data'].map { |n| n['data']['reference'] }
      expect(refs).to eq(%w[early late])
    end

    it 'does not skip a notification created later with an earlier due time (a lagging caller clock)' do
      authorize!(payment_method: 'pm_card_disputeFraudulent', capture: true)
      post_json('/payouts', { reference: 'po_x', merchant_id: 'm', amount: 100, currency: 'usd' },
                at: SimHelper::T0 + (9 * day))
      page = poll(at: SimHelper::T0 + (10 * day))
      expect(types(page)).to eq(['dispute.opened', 'payout.paid'])

      # Another caller, whose clock says day 8, resolves the dispute: due at day 8,
      # before everything the first consumer has already seen.
      call(:post, "/admin/disputes/#{simulator.disputes.first.id}/resolve", { outcome: 'won' },
           at: SimHelper::T0 + (8 * day))
      expect(types(poll(at: SimHelper::T0 + (10 * day), after: page['next_cursor']))).to eq(['dispute.closed'])
    end

    it 'hands every notification out exactly once to a consumer following next_cursor' do
      10.times do |i|
        post_json('/payouts', { reference: "po_#{i}", merchant_id: 'm', amount: 100 + i, currency: 'usd' },
                  at: SimHelper::T0 + (i * 7_200))
      end
      seen = []
      cursor = '0'
      (0..40).each do |hour|
        page = poll(at: SimHelper::T0 + day + (hour * 3_600), after: cursor, limit: 3)
        seen.concat(page['data'].map { |n| n['id'] })
        cursor = page['next_cursor']
      end
      expect(seen.size).to eq(10)
      expect(seen.uniq.size).to eq(10)
    end

    it 'requires Sim-Time and a numeric cursor' do
      expect(call(:get, '/notifications', at: nil).status).to eq(400)
      expect(call(:get, '/notifications?after=abc').status).to eq(400)
    end

    it 'forgets notifications on reset' do
      post_json('/payouts', { reference: 'po', merchant_id: 'm', amount: 100, currency: 'usd' })
      call(:post, '/admin/reset')
      expect(poll(at: SimHelper::T0 + day)['data']).to be_empty
    end
  end
end
