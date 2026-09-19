# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Routes::Reviews, :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  # A real card payment through the payments API, then the hold the risk
  # integration opens when RiskGate answers `review`.
  def review_payment(gross = 10_000)
    intent = create_intent(amount: gross)
    confirm(intent['id'])
    Clearinghouse::Balances::Holds.open_hold!(app_db, flow_id: intent['id'], merchant_id: merchant.id,
                                                      amount: money(gross), reason: 'rule:high_velocity', clock: clock)
  end

  def release!
    clock.advance(3 * BalanceHelpers::DAY)
    Clearinghouse::Balances::Availability.release_due!(app_db, clock: clock)
  end

  it 'shows a review in the shape of Stripe\'s Review object' do
    hold = review_payment
    get "/v1/reviews/#{hold.id}", {}, auth
    expect(last_response.status).to eq(200)
    expect(json_body).to eq('id' => hold.id, 'object' => 'review', 'payment_intent' => hold.flow_id,
                            'amount' => 10_000, 'currency' => 'usd', 'open' => true, 'opened_reason' => 'rule',
                            'reason' => 'rule:high_velocity', 'closed_reason' => nil,
                            'created' => clock.now.to_i, 'closed' => nil, 'livemode' => false)
  end

  it 'approves: the held money becomes available' do
    hold = review_payment
    release!
    expect(merchant_balance(merchant, 'held')).to eq(9_680)

    post "/v1/reviews/#{hold.id}/approve", '', auth
    expect(last_response.status).to eq(200)
    expect(json_body).to include('open' => false, 'closed_reason' => 'approved', 'closed' => clock.now.to_i)
    expect(merchant_balance(merchant, 'available')).to eq(9_680)
    expect(merchant_balance(merchant, 'held')).to eq(0)
  end

  it 'rejects: refunds the payment for real, and the held money only offsets the refund' do
    hold = review_payment
    release!
    post "/v1/reviews/#{hold.id}/reject", '', auth
    expect(last_response.status).to eq(200)
    expect(json_body).to include('open' => false, 'closed_reason' => 'refunded_as_fraud')

    refund = app_db[:refunds].where(payment_intent_id: hold.flow_id).first
    expect(refund).to include(amount: 10_000, status: 'succeeded', reason: 'fraudulent')
    expect(app_db[:risk_holds].where(id: hold.id).get(:refund_id)).to eq(refund[:id])
    expect(acquirer.calls_of(:refund).map(&:last)).to eq([refund[:id]])
    expect([merchant_balance(merchant, 'held'), merchant_balance(merchant, 'available')]).to eq([0, -320]) # fee kept
    expect(event_types(hold.id)).to eq(%w[review.opened review.closed])
    expect(app_db[:events].where(type: 'charge.refunded').count).to eq(1)
  end

  it 'rejects before the money is due: the refund posts first and the sweep then releases to available' do
    hold = review_payment
    post "/v1/reviews/#{hold.id}/reject", '', auth
    expect(merchant_balance(merchant, 'available')).to eq(-10_000)
    release!
    expect(merchant_balance(merchant, 'available')).to eq(-320)
    expect(merchant_balance(merchant, 'held')).to eq(0)
  end

  it 'leaves the review open when the refund cannot start' do
    hold = review_payment
    api_post('/v1/refunds', payment_intent: hold.flow_id) # the merchant already refunded it in full
    post "/v1/reviews/#{hold.id}/reject", '', auth
    expect(last_response.status).to eq(400)
    expect(json_body['error']).to include('code' => 'charge_already_refunded')
    expect(Clearinghouse::Balances::Holds.find(app_db, id: hold.id).open?).to be(true)
  end

  it 'refuses to close a review twice, and 404s one that is not the merchant\'s' do
    hold = review_payment
    post "/v1/reviews/#{hold.id}/approve", '', auth
    post "/v1/reviews/#{hold.id}/reject", '', auth
    expect(last_response.status).to eq(400)
    expect(json_body['error']).to include('type' => 'invalid_request_error', 'code' => 'review_closed')

    _, other_key = Clearinghouse::Merchants.create(app_db, clock: clock, name: 'Other', api_version: '2026-09-01')
    post "/v1/reviews/#{hold.id}/approve", '', { 'HTTP_AUTHORIZATION' => "Bearer #{other_key}" }
    expect(last_response.status).to eq(404)
    get '/v1/reviews/prv_missing', {}, auth
    expect(json_body['error']).to include('code' => 'resource_missing')
  end

  describe 'reject under an idempotency key' do
    def acquirer_refunds
      AcquirerSpec.simulator.operations.select { |o| o.type == 'refund' }
    end

    # Rejected, refunded once, held money released against the refund.
    def expect_rejected_once(hold)
      expect(Clearinghouse::Balances::Holds.find(app_db, id: hold.id))
        .to have_attributes(resolution: 'rejected', held_amount: 0)
      refunds = app_db[:refunds].where(payment_intent_id: hold.flow_id).all
      expect(refunds.map { |r| [r[:status], r[:amount]] }).to eq([['succeeded', 10_000]])
      expect(acquirer_refunds.map(&:idempotency_key)).to eq([refunds.first[:id]])
      expect([merchant_balance(merchant, 'held'), merchant_balance(merchant, 'available')]).to eq([0, -320])
      expect(app_db[:events].where(type: 'charge.refunded').count).to eq(1)
    end

    it 'replays the stored response for a retry and refunds once' do
      hold = review_payment
      release!
      first = api_post("/v1/reviews/#{hold.id}/reject", {}, 'HTTP_IDEMPOTENCY_KEY' => 'rj1')
      expect(first.status).to eq(200)
      again = api_post("/v1/reviews/#{hold.id}/reject", {}, 'HTTP_IDEMPOTENCY_KEY' => 'rj1')
      expect([again.status, again.body, again.headers['idempotent-replayed']]).to eq([200, first.body, 'true'])
      expect_rejected_once(hold)
    end

    it 'leaves the refund to the completer when the acquirer answer is lost, and it refunds once' do
      hold = review_payment
      release!
      acquirer.fail_next(:refund, :drop)
      response = api_post("/v1/reviews/#{hold.id}/reject", {}, 'HTTP_IDEMPOTENCY_KEY' => 'rj2')
      expect(response.status).to eq(503)
      expect(response.headers['clearinghouse-should-retry']).to eq('true')
      # Closed as rejected with its refund pending: the money stays held until the refund posts.
      expect(app_db[:refunds].where(payment_intent_id: hold.flow_id).get(:status)).to eq('pending')
      expect(merchant_balance(merchant, 'held')).to eq(9_680)
      key = app_db[:idempotency_keys].where(key: 'rj2').first
      expect(key).to include(flow: 'review.reject', recovery_point: 'refund_requested')

      clock.advance(60)
      report = Clearinghouse::Api::Completion.completer(deps, grace: 30).run_once
      expect([report.completed, report.failed]).to eq([[key[:id]], []])
      expect_rejected_once(hold)
      expect(acquirer.calls_of(:lookup).length).to eq(1) # asked before refunding again, and did not
      replay = api_post("/v1/reviews/#{hold.id}/reject", {}, 'HTTP_IDEMPOTENCY_KEY' => 'rj2')
      expect([replay.status, JSON.parse(replay.body)['closed_reason']]).to eq([200, 'refunded_as_fraud'])
    end

    # Every recovery point of review.reject, from the registry, at both moments.
    FlowCrashHelpers.crash_points('review.reject').each do |point|
      it "recovers from a crash at #{point}" do
        hold = review_payment
        release!
        path = "/v1/reviews/#{hold.id}/reject"
        input = Clearinghouse::Balances::ReviewFlows::Input.new(review_id: hold.id)
        expect do
          run_flow_directly(Clearinghouse::Balances::ReviewFlows::REJECT, input, path: path, key: 'crash',
                                                                                 crash_at: point)
        end.to raise_error(SimulatedCrash)

        report = complete_after_crash('crash')
        if report.nil?
          expect(point.to_s).to eq('review.reject:started:before_commit')
        else
          expect(report.failed).to eq([])
        end
        retry_response = api_post(path, {}, 'HTTP_IDEMPOTENCY_KEY' => 'crash')
        expect([retry_response.status, JSON.parse(retry_response.body)['closed_reason']])
          .to eq([200, 'refunded_as_fraud'])
        expect_rejected_once(hold)
      end
    end
  end

  it 'lists reviews newest first, filtered by open, with paging' do
    first = review_payment(1_000)
    clock.advance(1)
    second = review_payment(2_000)
    post "/v1/reviews/#{first.id}/approve", '', auth

    get '/v1/reviews', { 'open' => 'true' }, auth
    expect(json_body).to include('object' => 'list', 'url' => '/v1/reviews', 'has_more' => false)
    expect(json_body['data'].map { |r| r['id'] }).to eq([second.id])

    get '/v1/reviews', { 'limit' => '1' }, auth
    expect([json_body['data'].map { |r| r['id'] }, json_body['has_more']]).to eq([[second.id], true])
    get '/v1/reviews', { 'starting_after' => second.id }, auth
    expect(json_body['data'].map { |r| r['id'] }).to eq([first.id])

    get '/v1/reviews', { 'starting_after' => 'prv_missing' }, auth
    expect(json_body['error']).to include('param' => 'starting_after')
  end
end
