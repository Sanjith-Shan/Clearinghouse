# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Routes::Refunds, :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'

  def paid_intent(amount: 2000, payment_method: 'pm_card_visa', currency: 'usd')
    id = create_intent(amount: amount, payment_method: payment_method, currency: currency)['id']
    raise "confirm failed: #{last_response.body}" unless confirm(id).status == 200

    id
  end

  def refund(params)
    api_post('/v1/refunds', params)
  end

  describe 'POST /v1/refunds' do
    it 'refunds everything by default, posts the refund flow, and emits charge.refunded' do
      id = paid_intent
      response = refund(payment_intent: id, reason: 'requested_by_customer')
      expect(response.status).to eq(200)
      charge = intent_row(id)[:latest_charge]
      expect(json_body).to include('object' => 'refund', 'amount' => 2000, 'currency' => 'usd', 'status' => 'succeeded',
                                   'payment_intent' => id, 'charge' => charge, 'reason' => 'requested_by_customer',
                                   'failure_reason' => nil)
      # Our fee is not returned, and the refund comes out of available (docs/design/ledger.md).
      expect([balance('available'), balance('pending'), platform_balance('refund_clearing')])
        .to eq([-2000, 1912, 2000])
      expect(event_types(charge)).to eq(['charge.refunded'])
      event = ApiSpecHelpers.db[:events].where(object_id: charge).first
      expect(JSON.parse(event[:data])).to include('object' => 'charge', 'amount_refunded' => 2000, 'refunded' => true)
      expect(acquirer_charges(id).first.refunded).to eq(2000)
      expect(acquirer.calls_of(:refund)).to eq([[:refund, json_body['id']]])
      Clearinghouse::Ledger::Invariants.check!(ApiSpecHelpers.db)
    end

    it 'takes several partial refunds up to exactly what was captured, and no more' do
      id = paid_intent
      expect([refund(payment_intent: id, amount: 500), refund(payment_intent: id, amount: 700)].map(&:status))
        .to eq([200, 200])
      expect(json_body_of(refund(payment_intent: id, amount: 801))['error'])
        .to include('code' => 'parameter_invalid', 'param' => 'amount')
      expect(json_body_of(refund(payment_intent: id))).to include('amount' => 800, 'status' => 'succeeded')
      expect(json_body_of(refund(payment_intent: id,
                                 amount: 1))['error']).to include('code' => 'charge_already_refunded')
      expect(intent_row(id)[:amount_refunded]).to eq(2000)
      expect(ApiSpecHelpers.db[:ledger_transactions].where(flow_type: 'refund').count).to eq(3)
      expect(acquirer_charges(id).first.refunded).to eq(2000)
    end

    it 'refunds a partial capture only up to what was captured' do
      id = create_intent(amount: 5000, capture_method: 'manual')['id']
      confirm(id)
      capture(id, amount_to_capture: 1000)
      expect(json_body_of(refund(payment_intent: id))).to include('amount' => 1000)
    end

    it 'records a refund the acquirer refuses as failed and releases its reservation' do
      id = paid_intent(payment_method: 'pm_card_disputeFraudulent')
      clock.advance(7 * Clearinghouse::Clock::SECONDS_PER_DAY) # the simulator opens the dispute
      response = refund(payment_intent: id, amount: 500)
      expect(json_body_of(response)).to include('status' => 'failed', 'failure_reason' => 'charge_disputed')
      expect(intent_row(id)[:amount_refunded]).to eq(0)
      expect(ApiSpecHelpers.db[:ledger_transactions].where(flow_type: 'refund').count).to eq(0)
      expect(ApiSpecHelpers.db[:events].where(object_id: json_body_of(response)['id']).select_map(:type))
        .to eq(['charge.refund.updated'])
    end

    it 'keeps the reservation while the acquirer has not answered' do
      id = paid_intent
      acquirer.fail_next(:refund, :unavailable)
      expect(refund(payment_intent: id, amount: 500).status).to eq(503)
      expect(ApiSpecHelpers.db[:refunds].get(:status)).to eq('pending')
      expect(json_body_of(refund(payment_intent: id, amount: 1600))['error']).to include('param' => 'amount')
    end

    it 'never refunds more than was captured under concurrent refunds' do
      id = paid_intent
      statuses = Array.new(10) do
        Thread.new do
          Rack::MockRequest.new(app).post('/v1/refunds', input: "payment_intent=#{id}&amount=300",
                                                         'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
                                                         'HTTP_AUTHORIZATION' => "Bearer #{secret_key}").status
        end
      end.map(&:value)
      expect(statuses.tally).to eq(200 => 6, 400 => 4)
      expect(intent_row(id)[:amount_refunded]).to eq(1800)
      expect(acquirer_charges(id).first.refunded).to eq(1800)
    end

    Clearinghouse::Payments::StateMachine::Status.each_value do |state|
      next if state == Clearinghouse::Payments::StateMachine::Status::Succeeded

      it "refuses to refund an intent in #{state.serialize}, writing nothing" do
        intent = insert_intent(ApiSpecHelpers.db, merchant_id: merchant.id, status: state.serialize,
                                                  **(state.serialize == 'requires_capture' ? requires_capture : {}))
        before = write_counts
        response = refund(payment_intent: intent.id)
        expect(response.status).to eq(400)
        expect(json_body['error']).to include('code' => 'payment_intent_unexpected_state')
        expect([write_counts, ApiSpecHelpers.db[:refunds].count, acquirer.calls]).to eq([before, 0, []])
      end
    end

    it 'names the parameter for an unknown payment intent' do
      expect(json_body_of(refund(payment_intent: 'pi_nope'))['error']).to include('code' => 'resource_missing',
                                                                                  'param' => 'payment_intent')
    end
  end

  def requires_capture
    { amount_capturable: 2000, acquirer_reference: 'acq_x', authorization_expires_at: clock.now + 60, attempt: 1 }
  end

  def json_body_of(response)
    JSON.parse(response.body)
  end

  it 'retrieves a refund, and only for its merchant' do
    id = json_body_of(refund(payment_intent: paid_intent))['id']
    get "/v1/refunds/#{id}", {}, auth
    expect(json_body).to include('id' => id, 'status' => 'succeeded')
    _, other_key = Clearinghouse::Merchants.create(ApiSpecHelpers.db, clock: clock, name: 'Other',
                                                                      api_version: '2026-09-01')
    get "/v1/refunds/#{id}", {}, { 'HTTP_AUTHORIZATION' => "Bearer #{other_key}" }
    expect(last_response.status).to eq(404)
  end

  describe 'GET /v1/balance' do
    it 'is zero in USD for a merchant that has never been paid' do
      get '/v1/balance', {}, auth
      expect(json_body).to eq('object' => 'balance', 'available' => [{ 'amount' => 0, 'currency' => 'usd' }],
                              'pending' => [{ 'amount' => 0, 'currency' => 'usd' }], 'livemode' => false)
    end

    it 'reads pending and available per currency from the ledger' do
      paid_intent(amount: 2000)
      paid_intent(amount: 5000, currency: 'jpy')
      refund(payment_intent: paid_intent(amount: 1000), amount: 400)
      get '/v1/balance', {}, auth
      # usd: 1912 + 941 pending; the refund takes 400 from available. jpy: 5000 - 145 (2.9%), no fixed fee.
      expect(json_body['pending']).to eq([{ 'amount' => 4855, 'currency' => 'jpy' },
                                          { 'amount' => 2853, 'currency' => 'usd' }])
      expect(json_body['available']).to eq([{ 'amount' => 0, 'currency' => 'jpy' },
                                            { 'amount' => -400, 'currency' => 'usd' }])
    end
  end
end
