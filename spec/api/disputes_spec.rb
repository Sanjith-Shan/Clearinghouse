# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Routes::Disputes do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:db) { ApiSpecHelpers.db }
  let(:service) { Clearinghouse::Disputes::Service.new(clock: clock) }
  let(:other_merchant) do
    Clearinghouse::Merchants.create(db, clock: clock, name: 'Other', api_version: merchant_api_version).first
  end

  # A dispute.opened as the poller would hand it over, for a payment of `owner`.
  def open_dispute(owner, num, amount: 5_000)
    insert_intent(db, merchant_id: owner.id, status: 'succeeded', amount: amount, amount_received: amount,
                      acquirer_reference: "acq_#{num}")
    notification = Clearinghouse::Acquirer::Notification.new(
      id: "ntf_#{num}", type: 'dispute.opened', created_at: clock.now, cursor: num.to_s,
      data: { 'dispute_id' => "dsp_#{num}", 'acquirer_reference' => "acq_#{num}", 'amount' => amount,
              'currency' => 'usd', 'reason' => 'fraudulent' }
    )
    dispute = service.opened(db, notification)
    clock.advance(60)
    dispute
  end

  def close_at_acquirer(dispute, outcome)
    service.closed(db, Clearinghouse::Acquirer::Notification.new(
                         id: "ntf_c#{dispute.id}", type: 'dispute.closed', created_at: clock.now, cursor: '99',
                         data: { 'dispute_id' => dispute.acquirer_dispute_id, 'outcome' => outcome }
                       ))
  end

  describe 'GET /v1/disputes' do
    it "lists the merchant's own disputes newest first, a page at a time" do
      ids = Array.new(3) { |i| open_dispute(merchant, i).id }
      open_dispute(other_merchant, 9)

      get '/v1/disputes', { limit: 2 }, auth
      expect(last_response.status).to eq(200)
      expect(json_body).to include('object' => 'list', 'url' => '/v1/disputes', 'has_more' => true)
      expect(json_body['data'].map { |d| d['id'] }).to eq(ids.reverse.first(2))

      get '/v1/disputes', { limit: 2, starting_after: ids[1] }, auth
      expect(json_body).to include('has_more' => false)
      expect(json_body['data'].map { |d| d['id'] }).to eq([ids[0]])
    end

    it 'refuses an unknown cursor and unknown parameters' do
      get '/v1/disputes', { starting_after: 'dp_nope' }, auth
      expect(last_response.status).to eq(404)
      expect(json_body['error']).to include('code' => 'resource_missing', 'param' => 'starting_after')

      get '/v1/disputes', { status: 'won' }, auth
      expect(json_body['error']).to include('code' => 'parameter_unknown', 'param' => 'status')
    end
  end

  describe 'GET /v1/disputes/:id' do
    it 'returns the dispute in the shape RiskGate reads' do
      dispute = open_dispute(merchant, 1)
      get "/v1/disputes/#{dispute.id}", {}, auth
      expect(json_body).to eq('id' => dispute.id, 'object' => 'dispute', 'payment_intent' => dispute.payment_intent,
                              'amount' => 5_000,
                              'currency' => 'usd', 'reason' => 'fraudulent', 'status' => 'needs_response',
                              'fee' => 1_500, 'created' => Time.utc(2026, 9, 1, 12).to_i, 'livemode' => false)
    end

    it "is a 404 for another merchant's dispute" do
      dispute = open_dispute(other_merchant, 1)
      get "/v1/disputes/#{dispute.id}", {}, auth
      expect(last_response.status).to eq(404)
      expect(json_body['error']).to include('code' => 'resource_missing')
    end
  end

  describe 'POST /v1/disputes/:id/close' do
    it 'accepts the loss, and doing it again changes nothing' do
      dispute = open_dispute(merchant, 1)
      2.times do
        post "/v1/disputes/#{dispute.id}/close", {}, auth
        expect(last_response.status).to eq(200)
        expect(json_body).to include('id' => dispute.id, 'status' => 'lost')
      end
      expect(db[:events].where(object_id: dispute.id).order(:seq).select_map(:type))
        .to eq(%w[charge.dispute.created charge.dispute.closed])
      expect(db[:events].where(type: 'charge.dispute.closed').get(:request_id)).to start_with('req_')
    end

    it 'refuses to close a won dispute' do
      dispute = open_dispute(merchant, 1)
      close_at_acquirer(dispute, 'won')
      post "/v1/disputes/#{dispute.id}/close", {}, auth
      expect(last_response.status).to eq(400)
      expect(json_body['error']).to include('type' => 'invalid_request_error', 'code' => 'dispute_already_closed')
    end

    it "is a 404 for another merchant's dispute" do
      dispute = open_dispute(other_merchant, 1)
      post "/v1/disputes/#{dispute.id}/close", {}, auth
      expect(last_response.status).to eq(404)
    end
  end
end
