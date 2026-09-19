# typed: false
# frozen_string_literal: true

# Payouts and review decisions under the idempotency framework: HTTP replay,
# the bank's lost answer, a crash at every recovery point of payout.create
# (enumerated from the registry, as experiment 2 does), and concurrency.
RSpec.describe Clearinghouse::Payouts::Flows, :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  # Captures and lets the merchant's two-day delay pass. Returns the net.
  def fund(gross)
    _, net = capture!(merchant, gross, clock: clock)
    clock.advance(3 * BalanceHelpers::DAY)
    Clearinghouse::Balances::Availability.release_due!(app_db, clock: clock)
    net.amount
  end

  def payout(params = {}, key: nil)
    api_post('/v1/payouts', params, key ? { 'HTTP_IDEMPOTENCY_KEY' => key } : {})
  end

  def bank_payouts
    AcquirerSpec.simulator.payouts
  end

  it 'registers payout.create with exactly Payouts::RECOVERY_POINTS, so the crash matrix covers them' do
    registry = Clearinghouse::Payments::Flows.registry
    expect(registry.fetch('payout.create').recovery_points).to eq(Clearinghouse::Payouts::RECOVERY_POINTS)
    expect(registry.crash_points.map(&:to_s))
      .to include('payout.create:balance_reserved', 'payout.create:bank_requested:before_commit',
                  'payout.create:bank_recorded', 'payout.cancel:finished', 'review.approve:finished',
                  'review.reject:refund_requested')
  end

  describe 'POST /v1/payouts under an Idempotency-Key' do
    it 'replays the stored response for a retry and creates one payout' do
      fund(10_000)
      first = payout({ amount: 2_500 }, key: 'po-1')
      expect(first.status).to eq(200)
      again = payout({ amount: 2_500 }, key: 'po-1')
      expect([again.status, again.body]).to eq([200, first.body])
      expect(again.headers).to include('idempotent-replayed' => 'true')
      expect([app_db[:payouts].count, bank_payouts.length, merchant_balance(merchant, 'available')])
        .to eq([1, 1, 7_180])
    end

    it 'replays a refusal too, and refuses the key for a different request' do
      fund(10_000)
      refused = payout({ amount: 10_000 }, key: 'po-2')
      expect(JSON.parse(refused.body)['error']).to include('code' => 'balance_insufficient')
      expect(payout({ amount: 10_000 }, key: 'po-2').body).to eq(refused.body)
      reused = payout({ amount: 100 }, key: 'po-2')
      expect([reused.status, JSON.parse(reused.body)['error']['code']]).to eq([400, 'idempotency_key_reused'])
      expect(app_db[:payouts].count).to eq(0)
    end

    it 'answers a lost bank answer with a retryable 503; the retry asks the bank and does not pay twice' do
      fund(10_000)
      acquirer.fail_next(:payout, :drop)
      lost = payout({}, key: 'po-3')
      expect([lost.status, lost.headers['clearinghouse-should-retry']]).to eq([503, 'true'])
      expect(app_db[:idempotency_keys].where(key: 'po-3').get(:recovery_point)).to eq('bank_requested')
      expect(app_db[:payouts].get(%i[status recovery_point])).to eq(%w[pending bank_requested])

      retried = payout({}, key: 'po-3')
      expect(JSON.parse(retried.body)).to include('status' => 'in_transit', 'amount' => 9_680)
      expect(acquirer.calls.map(&:first)).to eq(%i[payout lookup])
      expect(bank_payouts.length).to eq(1)
    end

    it 'fails before reserving anything when the app has no bank to send to' do
      fund(10_000)
      no_bank = Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock)
      response = Rack::MockRequest.new(Clearinghouse::Api::App.new(no_bank))
                                  .post('/v1/payouts', 'HTTP_AUTHORIZATION' => "Bearer #{secret_key}")
      expect([response.status, app_db[:payouts].count]).to eq([500, 0])
    end
  end

  # Crash right before or right after each recovery point commits, then let the
  # completer (the restarted process) finish the request. However it stopped,
  # the bank ends up with exactly one payout and the client's retry gets it.
  describe 'recovery at every point of payout.create' do
    FlowCrashHelpers.crash_points('payout.create').each do |point|
      it "recovers from a crash at #{point}" do
        fund(10_000)
        input = described_class::CreateInput.new(currency: 'usd', amount: nil, description: nil, metadata: {})
        expect { run_flow_directly(described_class::CREATE, input, path: '/v1/payouts', key: 'crash', crash_at: point) }
          .to raise_error(SimulatedCrash)

        report = complete_after_crash('crash')
        expect(report&.failed || []).to eq([])
        retried = payout({}, key: 'crash')
        body = JSON.parse(retried.body)
        expect([retried.status, body['status'], body['amount']]).to eq([200, 'in_transit', 9_680])
        expect([bank_payouts.map(&:reference), acquirer.calls_of(:payout).length]).to eq([[body['id']], 1])
        expect(app_db[:payouts].get(%i[id recovery_point])).to eq([body['id'], 'bank_recorded'])
      end
    end
  end

  describe 'concurrent payouts against one balance through the API' do
    it 'never overdraws and never answers 500: exactly as many succeed as the balance covers' do
      fund(10_000) # 96.80 available
      gate = Queue.new
      threads = Array.new(12) do |i|
        Thread.new do
          gate.pop
          Rack::MockRequest.new(app).post('/v1/payouts', input: 'amount=1000',
                                                         'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
                                                         'HTTP_AUTHORIZATION' => "Bearer #{secret_key}",
                                                         'HTTP_IDEMPOTENCY_KEY' => "c#{i}").status
        end
      end
      12.times { gate << :go }
      expect(threads.map(&:value).tally).to eq(200 => 9, 400 => 3)
      expect([merchant_balance(merchant, 'available'), bank_payouts.sum(&:amount)]).to eq([680, 9_000])
    end
  end

  describe 'cancel and review decisions under an Idempotency-Key' do
    it 'replays a cancel instead of answering payout_not_cancelable the second time' do
      fund(10_000)
      reserved = Clearinghouse::Payouts.reserve!(app_db, merchant_id: merchant.id, currency: 'usd', clock: clock)
      first = api_post("/v1/payouts/#{reserved.id}/cancel", {}, 'HTTP_IDEMPOTENCY_KEY' => 'cx')
      again = api_post("/v1/payouts/#{reserved.id}/cancel", {}, 'HTTP_IDEMPOTENCY_KEY' => 'cx')
      expect([first.status, again.status, again.body]).to eq([200, 200, first.body])
      expect(JSON.parse(again.body)['status']).to eq('canceled')
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
    end

    it 'replays an approve instead of answering review_closed the second time' do
      intent = create_intent(amount: 10_000)
      confirm(intent['id'])
      hold = Clearinghouse::Balances::Holds.open_hold!(app_db, flow_id: intent['id'], merchant_id: merchant.id,
                                                               amount: money(10_000), reason: 'spec', clock: clock)
      first = api_post("/v1/reviews/#{hold.id}/approve", {}, 'HTTP_IDEMPOTENCY_KEY' => 'ap')
      again = api_post("/v1/reviews/#{hold.id}/approve", {}, 'HTTP_IDEMPOTENCY_KEY' => 'ap')
      expect([first.status, again.status, again.body]).to eq([200, 200, first.body])
      expect(api_post("/v1/reviews/#{hold.id}/approve").status).to eq(400) # a new request: review_closed
    end
  end
end
