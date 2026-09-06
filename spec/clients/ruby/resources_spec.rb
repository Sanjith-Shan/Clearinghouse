# typed: false
# frozen_string_literal: true

require_relative 'client_helper'

RSpec.describe ClearinghouseClient::Resources do
  let(:servers) { [] }

  after { servers.each(&:stop) }

  def serve(*script)
    ScriptedApiServer.new(*script).tap { |server| servers << server }
  end

  def client_for(server)
    ClearinghouseClient::Client.new(api_key: 'sk_test_client', base_url: server.url, sleeper: ->(_) {},
                                    rng: FixedRandom.new(0.5))
  end

  def decoded(request)
    URI.decode_www_form_component(request.request_line.split[1])
  end

  describe 'the helpers' do
    {
      'payment_intents.create' => [->(c) { c.payment_intents.create({ amount: 2000, currency: 'usd' }) },
                                   'POST /v1/payment_intents', { 'amount' => 2000, 'currency' => 'usd' }],
      'payment_intents.retrieve' => [->(c) { c.payment_intents.retrieve('pi_1') }, 'GET /v1/payment_intents/pi_1'],
      'payment_intents.confirm' => [->(c) { c.payment_intents.confirm('pi_1', { payment_method: 'pm_card_visa' }) },
                                    'POST /v1/payment_intents/pi_1/confirm', { 'payment_method' => 'pm_card_visa' }],
      'payment_intents.capture' => [->(c) { c.payment_intents.capture('pi_1', { amount_to_capture: 500 }) },
                                    'POST /v1/payment_intents/pi_1/capture', { 'amount_to_capture' => 500 }],
      'payment_intents.cancel' => [->(c) { c.payment_intents.cancel('pi_1') },
                                   'POST /v1/payment_intents/pi_1/cancel', {}],
      'payment_intents.list' => [->(c) { c.payment_intents.list(limit: 2) }, 'GET /v1/payment_intents?limit=2'],
      'refunds.create' => [->(c) { c.refunds.create({ payment_intent: 'pi_1', amount: 400 }) },
                           'POST /v1/refunds', { 'payment_intent' => 'pi_1', 'amount' => 400 }],
      'refunds.retrieve' => [->(c) { c.refunds.retrieve('re_1') }, 'GET /v1/refunds/re_1'],
      'payouts.create' => [->(c) { c.payouts.create(amount: 5000, currency: 'usd') },
                           'POST /v1/payouts', { 'amount' => 5000, 'currency' => 'usd' }],
      'payouts.retrieve' => [->(c) { c.payouts.retrieve('po_1') }, 'GET /v1/payouts/po_1'],
      'webhook_endpoints.create' => [->(c) { c.webhook_endpoints.create({ url: 'https://example.com/hook' }) },
                                     'POST /v1/webhook_endpoints', { 'url' => 'https://example.com/hook' }],
      'webhook_endpoints.list' => [->(c) { c.webhook_endpoints.list }, 'GET /v1/webhook_endpoints'],
      'webhook_endpoints.delete' => [->(c) { c.webhook_endpoints.delete('we_1') }, 'DELETE /v1/webhook_endpoints/we_1'],
      'balance.retrieve' => [->(c) { c.balance.retrieve }, 'GET /v1/balance'],
      'account.retrieve' => [->(c) { c.account.retrieve }, 'GET /v1/account'],
      'events.list' => [->(c) { c.events.list(type: 'payout.paid') }, 'GET /v1/events?type=payout.paid']
    }.each do |name, (invoke, target, body)|
      it "#{name} sends #{target} and returns the body as a Hash" do
        server = serve(ok({ 'id' => 'obj_1', 'object' => 'thing' }))
        expect(invoke.call(client_for(server))).to eq('id' => 'obj_1', 'object' => 'thing')

        request = server.requests.fetch(0)
        method = target.split.first
        expect("#{method} #{decoded(request)}").to eq(target)
        expect(JSON.parse(request.body)).to eq(body) if method == 'POST'
        expect(request.headers.key?('idempotency-key')).to eq(method != 'GET')
      end
    end

    it 'passes an idempotency key and a version through' do
      server = serve(ok)
      client_for(server).payment_intents.capture('pi_1', {}, idempotency_key: 'cap-1', api_version: '2026-01-01')
      headers = server.requests.fetch(0).headers
      expect(headers.values_at('idempotency-key', 'clearinghouse-version')).to eq(%w[cap-1 2026-01-01])
    end

    it 'merges a params Hash with keyword params, the keyword winning a clash' do
      server = serve(ok)
      client_for(server).refunds.create({ 'amount' => 100, payment_intent: 'pi_1' }, amount: 200)
      expect(JSON.parse(server.requests.fetch(0).body)).to eq('amount' => 200, 'payment_intent' => 'pi_1')
    end

    it 'refuses an empty id before sending anything' do
      server = serve(ok)
      client = client_for(server)
      expect { client.payment_intents.retrieve('') }.to raise_error(ArgumentError, /non-empty String/)
      expect(server.attempts).to eq(0)
    end

    it 'escapes ids so they cannot reach another path' do
      server = serve(ok)
      client_for(server).payment_intents.capture('pi_1/../../refunds x')
      expect(server.requests.fetch(0).request_line)
        .to eq('POST /v1/payment_intents/pi_1%2F..%2F..%2Frefunds%20x/capture HTTP/1.1')
    end
  end

  describe 'auto-pagination' do
    let(:ids) { (1..7).map { |i| "pi_#{i}" } }

    # Newest first, like the API: pages of `limit` after `starting_after`.
    def pager(ids)
      lambda do |request|
        query = URI.decode_www_form(request.request_line.split[1].split('?', 2)[1].to_s).to_h
        limit = Integer(query.fetch('limit', '10'))
        start = query['starting_after'] ? ids.index(query['starting_after']) + 1 : 0
        page = ids[start, limit]
        [200, {}, { 'object' => 'list', 'data' => page.map { |id| { 'id' => id } },
                    'has_more' => start + limit < ids.length }]
      end
    end

    it 'follows starting_after until has_more is false' do
      server = serve(pager(ids))
      seen = []
      client_for(server).payment_intents.each(limit: 3) { |intent| seen << intent['id'] }
      expect(seen).to eq(ids)
      expect(server.requests.map { |r| decoded(r) }).to eq(
        ['/v1/payment_intents?limit=3', '/v1/payment_intents?limit=3&starting_after=pi_3',
         '/v1/payment_intents?limit=3&starting_after=pi_6']
      )
    end

    it 'fetches lazily: taking two objects makes one request' do
      server = serve(pager(ids))
      expect(client_for(server).events.each(limit: 3).first(2).map { |e| e['id'] }).to eq(%w[pi_1 pi_2])
      expect(server.attempts).to eq(1)
    end

    it "replaces the caller's starting_after instead of sending it twice" do
      server = serve(pager(ids))
      seen = client_for(server).webhook_endpoints.each(limit: 4, starting_after: 'pi_1').map { |e| e['id'] }
      expect(seen).to eq(ids.drop(1))
      expect(decoded(server.requests.last)).to eq('/v1/webhook_endpoints?limit=4&starting_after=pi_5')
    end

    it 'pages backwards with ending_before when the caller started that way' do
      server = serve([200, {}, { 'data' => [{ 'id' => 'pi_4' }, { 'id' => 'pi_5' }], 'has_more' => true }],
                     [200, {}, { 'data' => [{ 'id' => 'pi_2' }, { 'id' => 'pi_3' }], 'has_more' => false }])
      seen = client_for(server).payment_intents.each(ending_before: 'pi_6', limit: 2).map { |e| e['id'] }
      expect(seen).to eq(%w[pi_4 pi_5 pi_2 pi_3])
      expect(decoded(server.requests.last)).to eq('/v1/payment_intents?ending_before=pi_4&limit=2')
    end

    it 'stops on an empty page even if the server claims there is more' do
      server = serve([200, {}, { 'data' => [], 'has_more' => true }])
      expect(client_for(server).payment_intents.each.to_a).to eq([])
      expect(server.attempts).to eq(1)
    end

    it 'retries a failed page with the policy like any other read' do
      server = serve(:drop, [200, {}, { 'data' => [{ 'id' => 'pi_1' }], 'has_more' => false }])
      expect(client_for(server).payment_intents.each.map { |e| e['id'] }).to eq(['pi_1'])
      expect(server.attempts).to eq(2)
    end
  end
end
