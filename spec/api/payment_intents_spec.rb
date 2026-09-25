# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Routes::PaymentIntents, :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'

  let(:status) { Clearinghouse::Payments::StateMachine::Status }
  let(:machine) { Clearinghouse::Payments::StateMachine }

  describe 'POST /v1/payment_intents' do
    it 'creates an intent in the fixture shape, waiting for confirmation, and emits payment_intent.created' do
      body = create_intent(amount: 2000, customer_email: 'jenny.rosen@example.com', metadata: { order_id: '6735' },
                           risk_fields: { ip: '203.0.113.7' })
      expect(body.keys).to eq(fixture('payment_intent').keys)
      expect(body).to include('amount' => 2000, 'currency' => 'usd', 'status' => 'requires_confirmation',
                              'capture_method' => 'automatic', 'payment_method' => 'pm_card_visa',
                              'metadata' => { 'order_id' => '6735' }, 'latest_charge' => nil, 'risk' => nil,
                              'created' => clock.now.to_i, 'livemode' => false)
      expect(JSON.parse(intent_row(body['id'])[:risk_fields])).to eq('ip' => '203.0.113.7')
      expect(event_types(body['id'])).to eq(['payment_intent.created'])
    end

    it 'starts at requires_payment_method without a payment method, and takes JSON bodies too' do
      post '/v1/payment_intents', JSON.generate(amount: 500, currency: 'JPY', capture_method: 'manual'),
           auth.merge('CONTENT_TYPE' => 'application/json')
      expect(json_body).to include('status' => 'requires_payment_method', 'currency' => 'jpy',
                                   'capture_method' => 'manual')
    end

    [
      [{ currency: 'usd' }, 'parameter_missing', 'amount'],
      [{ amount: 2000 }, 'parameter_missing', 'currency'],
      [{ amount: 2000, currency: 'xyz' }, 'parameter_invalid', 'currency'],
      [{ amount: 0, currency: 'usd' }, 'parameter_invalid', 'amount'],
      [{ amount: 30, currency: 'usd' }, 'amount_too_small', 'amount'],
      [{ amount: 2000, currency: 'usd', payment_method: 'pm_card_amex' }, 'resource_missing', 'payment_method'],
      [{ amount: 2000, currency: 'usd', capture_method: 'later' }, 'parameter_invalid', 'capture_method'],
      [{ amount: 2000, currency: 'usd', risk_fields: 'x' }, 'parameter_invalid', 'risk_fields'],
      [{ amount: 2000, currency: 'usd', confirm: 'true' }, 'parameter_unknown', 'confirm']
    ].each do |params, code, param|
      it "refuses #{params.inspect} with #{code} on #{param}, writing nothing" do
        response = api_post('/v1/payment_intents', params)
        expect(response.status).to eq(400)
        expect(json_body['error']).to include('type' => 'invalid_request_error', 'code' => code, 'param' => param)
        expect(ApiSpecHelpers.db[:payment_intents].count).to eq(0)
      end
    end
  end

  describe 'GET' do
    it 'retrieves an intent, and hides it from other merchants' do
      id = create_intent['id']
      get "/v1/payment_intents/#{id}", {}, auth
      expect(json_body).to include('id' => id, 'object' => 'payment_intent')
      _, other_key = Clearinghouse::Merchants.create(ApiSpecHelpers.db, clock: clock, name: 'Other',
                                                                        api_version: '2026-09-01')
      get "/v1/payment_intents/#{id}", {}, { 'HTTP_AUTHORIZATION' => "Bearer #{other_key}" }
      expect(last_response.status).to eq(404)
      expect(json_body['error']).to include('code' => 'resource_missing', 'param' => 'intent')
    end

    it 'lists newest first with limit and starting_after' do
      ids = (1..3).map do
        clock.advance(1)
        create_intent['id']
      end.reverse
      get '/v1/payment_intents', { limit: 2 }, auth
      expect(json_body).to include('object' => 'list', 'url' => '/v1/payment_intents', 'has_more' => true)
      expect(json_body['data'].map { |i| i['id'] }).to eq(ids[0, 2])
      get '/v1/payment_intents', { limit: 2, starting_after: ids[1] }, auth
      expect([json_body['data'].map { |i| i['id'] }, json_body['has_more']]).to eq([[ids[2]], false])
      get '/v1/payment_intents', { limit: 101 }, auth
      expect(json_body['error']).to include('param' => 'limit')
    end

    it 'renders at an old version, embedding the payment method and naming amount_captured' do
      id = create_intent['id']
      confirm(id)
      get "/v1/payment_intents/#{id}", {}, auth.merge('HTTP_CLEARINGHOUSE_VERSION' => '2026-01-01')
      expect(json_body).to include('amount_captured' => 2000)
      expect(json_body['payment_method']).to include('id' => 'pm_card_visa', 'object' => 'payment_method')
    end

    it 'expands latest_charge' do
      id = create_intent['id']
      charge = json_body_of(confirm(id))['latest_charge']
      get "/v1/payment_intents/#{id}", { expand: ['latest_charge'] }, auth
      expect(json_body['latest_charge']).to include('id' => charge, 'object' => 'charge', 'amount_captured' => 2000,
                                                    'payment_intent' => id, 'captured' => true)
    end
  end

  def json_body_of(response)
    JSON.parse(response.body)
  end

  describe 'confirm, automatic capture' do
    it 'charges the card once, posts the capture with our fee, and emits succeeded' do
      id = create_intent(amount: 2000)['id']
      response = confirm(id)
      expect(response.status).to eq(200)
      expect(json_body).to include('status' => 'succeeded', 'amount_received' => 2000, 'amount_capturable' => 0)
      expect(json_body['latest_charge']).to match(/\Ach_/)
      # 2.9% of 2000 is 58, plus 30.
      expect([balance('pending'), platform_balance('fee_revenue'), platform_balance('processor_receivable')])
        .to eq([1912, 88, 2000])
      expect(event_types(id)).to eq(%w[payment_intent.created payment_intent.succeeded])
      expect(acquirer_captures(id)).to eq(1)
      expect(acquirer.calls_of(:authorize)).to eq([[:authorize, "#{id}:authorize:1"]])
      Clearinghouse::Ledger::Invariants.check!(ApiSpecHelpers.db)
    end

    it 'takes the payment method on confirm when the intent has none' do
      id = create_intent(payment_method: nil)['id']
      expect(json_body_of(confirm(id)).dig('error', 'param')).to eq('payment_method')
      expect(intent_row(id)[:status]).to eq('requires_payment_method')
      expect(json_body_of(confirm(id, payment_method: 'pm_card_mastercard'))).to include(
        'status' => 'succeeded', 'payment_method' => 'pm_card_mastercard'
      )
    end
  end

  describe 'declines' do
    {
      'pm_card_chargeDeclined' => %w[card_declined generic_decline],
      'pm_card_insufficientFunds' => %w[card_declined insufficient_funds],
      'pm_card_expired' => %w[expired_card expired_card]
    }.each do |card, (code, decline_code)|
      it "returns a card_error for #{card} and leaves the intent ready for another card" do
        id = create_intent(payment_method: card)['id']
        response = confirm(id)
        expect(response.status).to eq(402)
        expect(json_body['error']).to include('type' => 'card_error', 'code' => code, 'decline_code' => decline_code)
        expect(response.headers['clearinghouse-should-retry']).to eq('false')
        row = intent_row(id)
        expect([row[:status], row[:payment_method]]).to eq(['requires_payment_method', nil])
        expect(JSON.parse(row[:last_payment_error])).to include('code' => code, 'decline_code' => decline_code,
                                                                'message' => json_body['error']['message'])
        expect(event_types(id)).to eq(%w[payment_intent.created payment_intent.payment_failed])
        expect(ApiSpecHelpers.db[:ledger_transactions].count).to eq(0)
      end
    end

    it 'confirms again with a new card as a new attempt, under a new acquirer key' do
      id = create_intent(payment_method: 'pm_card_insufficientFunds')['id']
      confirm(id)
      expect(json_body_of(confirm(id, payment_method: 'pm_card_visa'))).to include('status' => 'succeeded',
                                                                                   'last_payment_error' => nil)
      expect(acquirer.calls_of(:authorize).map(&:last)).to eq(["#{id}:authorize:1", "#{id}:authorize:2"])
      expect(acquirer_charges(id).map(&:approved)).to eq([false, true])
      expect(intent_row(id)[:attempt]).to eq(2)
    end
  end

  describe 'an acquirer that does not answer' do
    it 'leaves the intent processing with a retryable 503 and fails nothing (pm_card_timeout)' do
      id = create_intent(payment_method: 'pm_card_timeout')['id']
      response = confirm(id, {}, 'HTTP_IDEMPOTENCY_KEY' => 'k-timeout')
      expect(response.status).to eq(503)
      expect(json_body['error']).to include('type' => 'api_error', 'code' => 'acquirer_unavailable')
      expect(response.headers['clearinghouse-should-retry']).to eq('true')
      expect(intent_row(id)[:status]).to eq('processing')
      # The acquirer did commit it; recovering from exactly this is the idempotency layer's job.
      expect(acquirer_captures(id)).to eq(1)
      expect([event_types(id), ApiSpecHelpers.db[:ledger_transactions].count])
        .to eq([['payment_intent.created'], 0])
    end

    it 'sends no retry header without an Idempotency-Key, where a retry is a new request' do
      id = create_intent['id']
      acquirer.fail_next(:authorize, :unavailable)
      response = confirm(id)
      expect(response.status).to eq(503)
      expect(response.headers).not_to have_key('clearinghouse-should-retry')
    end
  end

  describe 'manual capture' do
    let(:intent_id) do
      id = create_intent(amount: 5000, capture_method: 'manual')['id']
      confirm(id)
      id
    end

    it 'authorizes without moving money, then a partial capture posts what was captured and releases the rest' do
      expect(intent_row(intent_id)).to include(status: 'requires_capture', amount_capturable: 5000)
      expect(write_counts[:ledger_transactions]).to eq(0)
      response = capture(intent_id, amount_to_capture: 3000)
      expect(JSON.parse(response.body)).to include('status' => 'succeeded', 'amount_received' => 3000,
                                                   'amount_capturable' => 0, 'amount' => 5000)
      # 2.9% of 3000 is 87, plus 30.
      expect([balance('pending'), platform_balance('fee_revenue')]).to eq([2883, 117])
      expect(event_types(intent_id)).to eq(%w[payment_intent.created payment_intent.amount_capturable_updated
                                              payment_intent.succeeded])
      expect(AcquirerSpec.simulator.authorizations.first.captured).to eq(3000)
    end

    it 'captures everything by default' do
      expect(JSON.parse(capture(intent_id).body)).to include('amount_received' => 5000)
    end

    it 'refuses more than was authorized, and too little to cover the fee' do
      expect(JSON.parse(capture(intent_id, amount_to_capture: 5001).body)['error'])
        .to include('code' => 'parameter_invalid', 'param' => 'amount_to_capture')
      expect(JSON.parse(capture(intent_id, amount_to_capture: 20).body)['error'])
        .to include('code' => 'amount_too_small')
      expect(intent_row(intent_id)[:status]).to eq('requires_capture')
    end

    it 'cancels by voiding the authorization at the acquirer' do
      response = cancel(intent_id, cancellation_reason: 'requested_by_customer')
      expect(JSON.parse(response.body)).to include('status' => 'canceled', 'amount_capturable' => 0,
                                                   'cancellation_reason' => 'requested_by_customer')
      expect(AcquirerSpec.simulator.authorizations.first.voided).to be(true)
      expect(event_types(intent_id).last).to eq('payment_intent.canceled')
      expect(write_counts[:ledger_transactions]).to eq(0)
    end

    it 'expires after the TTL: capture is refused, and the sweep cancels it' do
      intent_id
      clock.advance(7 * Clearinghouse::Clock::SECONDS_PER_DAY)
      expect(JSON.parse(capture(intent_id).body)['error']).to include('code' => 'payment_intent_authorization_expired')
      expect(Clearinghouse::Payments::Expiry.sweep!(deps)).to eq([intent_id])
      expect(intent_row(intent_id)).to include(status: 'canceled', cancellation_reason: 'automatic')
      event = ApiSpecHelpers.db[:events].where(object_id: intent_id).order(:seq).last
      expect([event[:type], event[:request_id]]).to eq(['payment_intent.canceled', nil])
      expect(Clearinghouse::Payments::Expiry.sweep!(deps)).to eq([])
    end

    it 'reports a capture the acquirer refuses as capture_failed and leaves the intent capturable' do
      # The acquirer voided the authorization on its side, so it refuses the capture.
      acquirer.void(acquirer_reference: intent_row(intent_id)[:acquirer_reference], idempotency_key: 'void_out_of_band')
      response = capture(intent_id)
      expect(response.status).to eq(400)
      expect(JSON.parse(response.body)['error'])
        .to include('code' => 'capture_failed',
                    'message' => 'The capture was refused by the card network (authorization_voided).')
      expect(intent_row(intent_id)).to include(status: 'requires_capture', amount_capturable: 5000)
      expect(write_counts[:ledger_transactions]).to eq(0)
    end

    it 'does not expire an intent that was captured after the sweep read it' do
      capture(intent_id)
      clock.advance(7 * Clearinghouse::Clock::SECONDS_PER_DAY)
      expect(Clearinghouse::Payments::Expiry.expire!(deps, intent_id, merchant.id)).to be_nil
      expect(intent_row(intent_id)).to include(status: 'succeeded', cancellation_reason: nil)
    end

    it 'refuses an approval for an intent that is no longer waiting on one' do
      ctx = Clearinghouse::Api::Context.background(deps, merchant)
      operation = Clearinghouse::Acquirer::Operation.new(
        id: 'op_late', type: 'authorize', status: 'approved', decline_code: nil, acquirer_reference: 'acq_late',
        reference: intent_id, amount: 5000, currency: 'usd', idempotency_key: "#{intent_id}:authorize:1",
        created_at: clock.now
      )
      db = ApiSpecHelpers.db
      expect do
        db.transaction do
          Clearinghouse::Payments::Confirm.record_authorization!(
            db, ctx, intent_id, Clearinghouse::Acquirer::Approved.new(operation: operation)
          )
        end
      end.to raise_error(Clearinghouse::Api::Errors::InvalidRequestError) { |e|
        expect(e.code).to eq('payment_intent_unexpected_state')
      }
      expect(intent_row(intent_id)).to include(status: 'requires_capture')
      expect(intent_row(intent_id)[:acquirer_reference]).not_to eq('acq_late')
    end

    it 'does not expire an authorization before its time' do
      intent_id
      clock.advance((7 * Clearinghouse::Clock::SECONDS_PER_DAY) - 1)
      expect(Clearinghouse::Payments::Expiry.sweep!(deps)).to eq([])
    end
  end

  it 'cancels an intent that was never authorized without calling the acquirer' do
    id = create_intent['id']
    expect(JSON.parse(cancel(id).body)).to include('status' => 'canceled', 'cancellation_reason' => nil)
    expect(acquirer.calls).to be_empty
  end

  # Every (status, request) pair the transition table does not allow, over HTTP.
  # Each must be refused with the typed error and leave no trace: no ledger rows,
  # no events, the intent unchanged, and nothing sent to the acquirer.
  describe 'illegal transitions, generated from the table' do
    def intent_in(state)
      extra = case state
              when 'requires_capture'
                { amount_capturable: 2000, acquirer_reference: 'acq_x', latest_charge: Clearinghouse::Ids.generate('ch'),
                  authorization_expires_at: clock.now + 86_400, attempt: 1, capture_method: 'manual' }
              when 'succeeded' then { amount_received: 2000, acquirer_reference: 'acq_x', attempt: 1 }
              when 'processing' then { attempt: 1 }
              else {}
              end
      insert_intent(ApiSpecHelpers.db, merchant_id: merchant.id, status: state, **extra)
    end

    # The request that asks for each event.
    def request_for(event, intent_id)
      case event
      when 'confirm' then confirm(intent_id)
      when 'capture' then capture(intent_id)
      when 'cancel' then cancel(intent_id)
      else raise "no request for #{event}"
      end
    end

    Clearinghouse::Payments::StateMachine.illegal_pairs.each do |from, event|
      next unless Clearinghouse::Payments::StateMachine::REQUEST_EVENTS.key?(event)
      next if event.serialize == 'refund' # covered with the refunds endpoint

      it "refuses #{event.serialize} from #{from.serialize} and writes nothing" do
        intent = intent_in(from.serialize)
        before_row = intent_row(intent.id)
        before_counts = write_counts
        response = request_for(event.serialize, intent.id)
        expect(response.status).to eq(400)
        expect(JSON.parse(response.body)['error']).to include('type' => 'invalid_request_error',
                                                              'code' => 'payment_intent_unexpected_state')
        expect(write_counts).to eq(before_counts)
        expect(intent_row(intent.id)).to eq(before_row)
        expect(acquirer.calls).to be_empty
      end
    end
  end
end
