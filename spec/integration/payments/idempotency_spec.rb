# typed: false
# frozen_string_literal: true

# The Idempotency-Key contract over HTTP, on the real payments flows and the real
# acquirer simulator.
RSpec.describe 'Idempotency-Key on the payments API', :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'

  def with_key(key) = { 'HTTP_IDEMPOTENCY_KEY' => key }

  def ledger_captures(id)
    ApiSpecHelpers.db[:ledger_transactions].where(flow_id: id, description: 'capture').count
  end

  describe 'a finished request' do
    it 'replays byte for byte, same status, marked as a replay, without calling anyone again' do
      id = create_intent['id']
      first = confirm(id, {}, with_key('k1'))
      first_body = first.body
      first_request = first.headers['request-id']
      clock.advance(60)
      second = confirm(id, {}, with_key('k1'))
      expect([second.status, second.body]).to eq([200, first_body])
      expect(second.headers).to include('idempotent-replayed' => 'true', 'original-request' => first_request,
                                        'clearinghouse-version' => '2026-09-01')
      expect(first.headers).not_to have_key('idempotent-replayed')
      expect(acquirer.calls_of(:authorize).length).to eq(1)
      expect([acquirer_captures(id), ledger_captures(id)]).to eq([1, 1])
      expect(event_types(id)).to eq(%w[payment_intent.created payment_intent.succeeded])
    end

    it 'replays at the version first used, even if the retry asks for another' do
      id = create_intent['id']
      first = confirm(id, {}, with_key('k1').merge('HTTP_CLEARINGHOUSE_VERSION' => '2026-01-01'))
      again = confirm(id, {}, with_key('k1'))
      expect(again.body).to eq(first.body)
      expect(JSON.parse(again.body)).to include('amount_captured' => 2000)
    end

    it 'replays a decline, which is the answer to that request, with Should-Retry false' do
      id = create_intent(payment_method: 'pm_card_chargeDeclined')['id']
      first = confirm(id, {}, with_key('k1'))
      again = confirm(id, {}, with_key('k1'))
      expect([again.status, again.body, again.headers['clearinghouse-should-retry']]).to eq([402, first.body, 'false'])
      expect(acquirer.calls_of(:authorize).length).to eq(1)
    end

    it 'replays a create as the same intent' do
      first = api_post('/v1/payment_intents', { amount: 2000, currency: 'usd' }, with_key('c1')).body
      second = api_post('/v1/payment_intents', { amount: 2000, currency: 'usd' }, with_key('c1')).body
      expect(second).to eq(first)
      expect(ApiSpecHelpers.db[:payment_intents].count).to eq(1)
    end

    it 'treats the same request sent as JSON as the same request' do
      id = create_intent(capture_method: 'manual')['id']
      confirm(id)
      form = capture(id, { amount_to_capture: 1500 }, with_key('cap'))
      post "/v1/payment_intents/#{id}/capture", JSON.generate(amount_to_capture: 1500),
           auth.merge(with_key('cap')).merge('CONTENT_TYPE' => 'application/json')
      expect([last_response.body, last_response.headers['idempotent-replayed']]).to eq([form.body, 'true'])
    end
  end

  describe 'the same key with different parameters' do
    it 'is a 400 idempotency_error that retrying cannot fix' do
      id = create_intent['id']
      confirm(id, {}, with_key('k1'))
      response = confirm(id, { payment_method: 'pm_card_mastercard' }, with_key('k1'))
      expect(response.status).to eq(400)
      expect(json_body['error']).to include('type' => 'idempotency_error', 'code' => 'idempotency_key_reused')
      expect(response.headers['clearinghouse-should-retry']).to eq('false')
    end

    it 'is refused on a different endpoint too' do
      id = create_intent['id']
      confirm(id, {}, with_key('k1'))
      expect(cancel(id, {}, with_key('k1')).status).to eq(400)
    end

    it 'is scoped per merchant: another merchant may use the same key' do
      id = create_intent['id']
      confirm(id, {}, with_key('shared'))
      other, other_key = Clearinghouse::Merchants.create(ApiSpecHelpers.db, clock: clock, name: 'Other',
                                                                            api_version: '2026-09-01')
      post '/v1/payment_intents', 'amount=2000&currency=usd',
           { 'HTTP_AUTHORIZATION' => "Bearer #{other_key}", 'HTTP_IDEMPOTENCY_KEY' => 'shared',
             'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
      expect(last_response.status).to eq(200)
      expect(ApiSpecHelpers.db[:idempotency_keys].where(key: 'shared').select_map(:merchant_id))
        .to contain_exactly(merchant.id, other.id)
    end
  end

  it 'answers 409 while the first request is still running, and never runs twice' do
    id = create_intent['id']
    ApiSpecHelpers.db[:idempotency_keys].insert(
      merchant_id: merchant.id, key: 'k1', client_supplied: true, flow: 'payment_intent.confirm',
      flow_input: Sequel.cast(JSON.generate('intent_id' => id), :json), request_method: 'POST',
      request_path: "/v1/payment_intents/#{id}/confirm",
      request_fingerprint: Clearinghouse::Idempotency::Fingerprint.compute(
        method: 'POST', path: "/v1/payment_intents/#{id}/confirm", params: {}
      ), request_id: 'req_x', render_options: Sequel.cast('{"api_version":"2026-09-01","expand":[]}', :json),
      recovery_point: 'started', locked_at: clock.now, lock_token: 'live', last_run_at: clock.now, created_at: clock.now
    )
    response = confirm(id, {}, with_key('k1'))
    expect(response.status).to eq(409)
    expect(json_body['error']).to include('type' => 'idempotency_error', 'code' => 'idempotency_key_in_use')
    expect(response.headers['clearinghouse-should-retry']).to eq('true')
    expect(acquirer.calls).to be_empty
  end

  it 'refuses an empty or overlong key' do
    id = create_intent['id']
    expect(JSON.parse(confirm(id, {},
                              with_key('x' * 256)).body)['error']).to include('code' => 'idempotency_key_invalid')
    expect(confirm(id, {}, with_key(' ')).status).to eq(400)
    expect(confirm(id, {}, with_key('x' * 255)).status).to eq(200)
  end

  it 'forgets a key after 24 hours, and then it can be used for another request' do
    first = create_intent['id']
    confirm(first, {}, with_key('daily'))
    second = create_intent['id']
    expect(confirm(second, {}, with_key('daily')).status).to eq(400)
    clock.advance(24 * 3600)
    expect(JSON.parse(confirm(second, {}, with_key('daily')).body)).to include('id' => second, 'status' => 'succeeded')
  end

  # The ambiguous foreign call: the acquirer may have charged the card and the
  # answer was lost. The retry asks the acquirer about the attempt's key and only
  # authorizes if the acquirer has nothing under it.
  describe 'an acquirer answer that never arrived' do
    it 'resolves pm_card_timeout on retry by asking, and charges exactly once' do
      id = create_intent(payment_method: 'pm_card_timeout')['id']
      first = confirm(id, {}, with_key('k1'))
      expect([first.status, first.headers['clearinghouse-should-retry']]).to eq([503, 'true'])
      row = ApiSpecHelpers.db[:idempotency_keys].where(key: 'k1').first
      expect(row).to include(recovery_point: 'authorization_requested', locked_at: nil)
      again = confirm(id, {}, with_key('k1'))
      expect(JSON.parse(again.body)).to include('status' => 'succeeded')
      expect(again.headers).not_to have_key('idempotent-replayed')
      expect(acquirer.calls.map(&:first)).to eq(%i[authorize lookup])
      expect([acquirer_charges(id).length, acquirer_captures(id), ledger_captures(id)]).to eq([1, 1, 1])
      expect(event_types(id)).to eq(%w[payment_intent.created payment_intent.succeeded])
    end

    it 'resolves a response dropped after the acquirer committed, for any card' do
      id = create_intent['id']
      acquirer.fail_next(:authorize, :drop)
      expect(confirm(id, {}, with_key('k1')).status).to eq(503)
      expect(acquirer_captures(id)).to eq(1)
      expect(confirm(id, {}, with_key('k1')).status).to eq(200)
      expect([acquirer.calls_of(:authorize).length, acquirer_captures(id), ledger_captures(id)]).to eq([1, 1, 1])
    end

    it 'authorizes on retry when the acquirer never got the first request' do
      id = create_intent['id']
      acquirer.fail_next(:authorize, :unknown_unsent)
      expect(confirm(id, {}, with_key('k1')).status).to eq(503)
      expect(acquirer_charges(id)).to be_empty
      expect(confirm(id, {}, with_key('k1')).status).to eq(200)
      expect(acquirer.calls.map(&:first)).to eq(%i[authorize lookup authorize])
      expect(acquirer.calls.map(&:last).uniq).to eq(["#{id}:authorize:1"])
      expect(acquirer_captures(id)).to eq(1)
    end

    it 'keeps waiting while the status query itself goes unanswered' do
      id = create_intent['id']
      acquirer.fail_next(:authorize, :drop)
      confirm(id, {}, with_key('k1'))
      acquirer.fail_next(:lookup, :unavailable)
      expect(confirm(id, {}, with_key('k1')).status).to eq(503)
      expect(confirm(id, {}, with_key('k1')).status).to eq(200)
      expect(acquirer_captures(id)).to eq(1)
    end

    it 'resolves a declined authorization whose answer was lost into the same decline' do
      id = create_intent(payment_method: 'pm_card_insufficientFunds')['id']
      acquirer.fail_next(:authorize, :drop)
      confirm(id, {}, with_key('k1'))
      again = confirm(id, {}, with_key('k1'))
      expect([again.status, JSON.parse(again.body).dig('error', 'decline_code')]).to eq([402, 'insufficient_funds'])
      expect(acquirer.calls_of(:authorize).length).to eq(1)
    end

    it 'treats a new confirmation after a decline as a new attempt with a new acquirer key' do
      id = create_intent(payment_method: 'pm_card_insufficientFunds')['id']
      declined = confirm(id, {}, with_key('first'))
      expect(confirm(id, { payment_method: 'pm_card_visa' }, with_key('second')).status).to eq(200)
      expect(acquirer.calls_of(:authorize).map(&:last)).to eq(["#{id}:authorize:1", "#{id}:authorize:2"])
      # The first key still answers what it answered.
      expect(confirm(id, {}, with_key('first')).body).to eq(declined.body)
    end

    it 'without a key, a retry is a new request that the state machine refuses' do
      id = create_intent(payment_method: 'pm_card_timeout')['id']
      expect(confirm(id).status).to eq(503)
      expect(JSON.parse(confirm(id).body)['error']).to include('code' => 'payment_intent_unexpected_state')
      expect(acquirer_charges(id).length).to eq(1)
      expect(ApiSpecHelpers.db[:idempotency_keys].where(client_supplied: false,
                                                        recovery_point: 'authorization_requested')
                                                 .count).to eq(1)
    end

    it 'resolves a capture whose answer was lost' do
      id = create_intent(capture_method: 'manual')['id']
      confirm(id)
      acquirer.fail_next(:capture, :drop)
      expect(capture(id, { amount_to_capture: 1500 }, with_key('cap')).status).to eq(503)
      expect(JSON.parse(capture(id, { amount_to_capture: 1500 }, with_key('cap')).body))
        .to include('status' => 'succeeded', 'amount_received' => 1500)
      expect([acquirer.calls_of(:capture).length, ledger_captures(id)]).to eq([1, 1])
    end

    it 'resolves a refund whose answer was lost, refunding once' do
      id = create_intent['id']
      confirm(id)
      acquirer.fail_next(:refund, :drop)
      expect(api_post('/v1/refunds', { payment_intent: id, amount: 500 }, with_key('r1')).status).to eq(503)
      body = JSON.parse(api_post('/v1/refunds', { payment_intent: id, amount: 500 }, with_key('r1')).body)
      expect(body).to include('status' => 'succeeded', 'amount' => 500)
      expect([acquirer_charges(id).first.refunded, ApiSpecHelpers.db[:refunds].count]).to eq([500, 1])
    end
  end

  describe 'one request at a time per PaymentIntent' do
    it 'refuses a capture while a cancel of the same intent is between its phases, without storing the refusal' do
      id = create_intent(capture_method: 'manual')['id']
      confirm(id)
      acquirer.fail_next(:void, :unavailable)
      expect(cancel(id, {}, with_key('cancel')).status).to eq(503) # the cancel now holds the intent
      response = capture(id, {}, with_key('cap'))
      expect([response.status, JSON.parse(response.body).dig('error', 'code')]).to eq([409, 'lock_timeout'])
      expect(response.headers['clearinghouse-should-retry']).to eq('true')
      expect(ApiSpecHelpers.db[:idempotency_keys].where(key: 'cap').get(:recovery_point)).to eq('started')
      expect(JSON.parse(cancel(id, {}, with_key('cancel')).body)).to include('status' => 'canceled')
      expect(ApiSpecHelpers.db[:payment_intents].where(id: id).get(:locked_by)).to be_nil
      # The capture's key was not burned by the 409: retried, it now meets a canceled intent.
      expect(JSON.parse(capture(id, {}, with_key('cap')).body).dig('error', 'code'))
        .to eq('payment_intent_unexpected_state')
      expect(AcquirerSpec.simulator.authorizations.first.captured).to eq(0)
    end
  end
end
