# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Routes::Payouts, :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include PayoutHelpers

  let(:deps) do
    Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock, log: nil, acquirer: bank)
  end

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  # Captures and lets the merchant's two-day delay pass. Returns the net.
  def fund(gross)
    _, net = capture!(merchant, gross, clock: clock)
    clock.advance(3 * BalanceHelpers::DAY)
    Clearinghouse::Balances::Availability.release_due!(app_db, clock: clock)
    net.amount
  end

  def create_payout(body = '')
    post '/v1/payouts', body, auth.merge('CONTENT_TYPE' => 'application/x-www-form-urlencoded')
  end

  describe 'POST /v1/payouts' do
    it 'pays out the whole available balance when no amount is given' do
      fund(10_000)
      create_payout
      expect(last_response.status).to eq(200)
      expect(json_body).to include('object' => 'payout', 'amount' => 9_680, 'currency' => 'usd',
                                   'status' => 'in_transit', 'automatic' => false, 'method' => 'standard',
                                   'failure_code' => nil, 'failure_message' => nil, 'livemode' => false,
                                   'created' => clock.now.to_i, 'arrival_date' => clock.now.to_i + 86_400)
      expect(json_body['id']).to match(/\Apo_[A-Za-z0-9]{24}\z/)
      expect(merchant_balance(merchant, 'available')).to eq(0)
    end

    it 'takes an amount, a description and metadata' do
      fund(10_000)
      create_payout('amount=2500&currency=usd&description=Weekly&metadata[run]=7')
      expect(json_body).to include('amount' => 2_500, 'description' => 'Weekly', 'metadata' => { 'run' => '7' })
      expect(merchant_balance(merchant, 'available')).to eq(7_180)
    end

    it 'refuses with balance_insufficient when the balance cannot cover it' do
      fund(10_000)
      create_payout('amount=10000')
      expect(last_response.status).to eq(400)
      expect(json_body['error']).to include('type' => 'invalid_request_error', 'code' => 'balance_insufficient',
                                            'param' => 'amount')
      expect(json_body['error']['message']).to include('96.80 USD')
      expect(last_response.headers['clearinghouse-should-retry']).to eq('false')
    end

    it 'refuses with balance_insufficient when nothing is available' do
      create_payout
      expect(json_body['error']).to include('code' => 'balance_insufficient')
      expect(app_db[:payouts].count).to eq(0)
    end

    context 'without an acquirer client' do
      let(:deps) { Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock, log: nil) }

      it 'fails with an api_error before reserving anything' do
        fund(10_000)
        create_payout
        expect(last_response.status).to eq(500)
        expect(app_db[:payouts].count).to eq(0)
      end
    end

    [
      ['amount=0', 'amount', 'parameter_invalid'],
      ['amount=12.5', 'amount', 'parameter_invalid'],
      ['currency=xyz', 'currency', 'parameter_invalid'],
      ['destination=ba_1', 'destination', 'parameter_unknown']
    ].each do |body, param, code|
      it "rejects #{body.inspect} naming #{param}" do
        create_payout(body)
        expect(last_response.status).to eq(400)
        expect(json_body['error']).to include('param' => param, 'code' => code)
      end
    end
  end

  describe 'GET /v1/payouts/:id' do
    it 'returns the payout, and 404 for another merchant' do
      fund(10_000)
      create_payout
      id = json_body['id']

      get "/v1/payouts/#{id}", {}, auth
      expect(json_body).to include('id' => id, 'status' => 'in_transit')

      _, other_key = Clearinghouse::Merchants.create(app_db, clock: clock, name: 'Other', api_version: '2026-09-01')
      get "/v1/payouts/#{id}", {}, { 'HTTP_AUTHORIZATION' => "Bearer #{other_key}" }
      expect(last_response.status).to eq(404)
      expect(json_body['error']).to include('code' => 'resource_missing', 'param' => 'id')
    end
  end

  describe 'GET /v1/payouts' do
    it 'lists newest first and pages with starting_after' do
      fund(10_000)
      ids = Array.new(3) do
        create_payout('amount=1000')
        clock.advance(1)
        json_body['id']
      end

      get '/v1/payouts', { 'limit' => '2' }, auth
      expect(json_body).to include('object' => 'list', 'url' => '/v1/payouts', 'has_more' => true)
      expect(json_body['data'].map { |p| p['id'] }).to eq(ids.reverse.first(2))

      get '/v1/payouts', { 'limit' => '2', 'starting_after' => ids[1] }, auth
      expect(json_body).to include('has_more' => false)
      expect(json_body['data'].map { |p| p['id'] }).to eq([ids[0]])
    end

    it 'filters by status and rejects an unknown cursor' do
      fund(10_000)
      create_payout('amount=1000')
      get '/v1/payouts', { 'status' => 'paid' }, auth
      expect(json_body['data']).to eq([])
      get '/v1/payouts', { 'status' => 'in_transit' }, auth
      expect(json_body['data'].length).to eq(1)

      get '/v1/payouts', { 'starting_after' => 'po_missing' }, auth
      expect(last_response.status).to eq(404)
      expect(json_body['error']).to include('param' => 'starting_after')
    end
  end

  describe 'POST /v1/payouts/:id/cancel' do
    it 'cancels a payout that has not gone to the bank and returns the money' do
      fund(10_000)
      payout = Clearinghouse::Payouts.reserve!(app_db, merchant_id: merchant.id, currency: 'usd', clock: clock)
      post "/v1/payouts/#{payout.id}/cancel", '', auth
      expect(last_response.status).to eq(200)
      expect(json_body).to include('id' => payout.id, 'status' => 'canceled')
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
    end

    it 'refuses a payout already sent, and 404s an unknown one' do
      fund(10_000)
      create_payout
      post "/v1/payouts/#{json_body['id']}/cancel", '', auth
      expect(last_response.status).to eq(400)
      expect(json_body['error']).to include('code' => 'payout_not_cancelable')

      post '/v1/payouts/po_missing/cancel', '', auth
      expect(last_response.status).to eq(404)
    end
  end
end
