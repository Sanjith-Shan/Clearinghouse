# typed: false
# frozen_string_literal: true

# M6's "safer payouts", end to end through the API: the real confirm flow asks the
# fake RiskGate over real sockets, which answers `review`; the real simulator
# authorizes and captures; the hold opened at capture keeps the money out of
# payouts until the review is closed. Nothing here is stubbed below the HTTP API
# except RiskGate's decision and the clock.
RSpec.describe 'A reviewed payment and payouts', :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'
  include FakeRiskgateHelper

  let(:deps) do
    Clearinghouse::Api::Dependencies.new(
      db: ApiSpecHelpers.db, clock: clock, log: log, acquirer: acquirer,
      risk_client: Clearinghouse::Risk::Client.new(base_url: riskgate_url, deadline_ms: 2_000)
    )
  end

  # After every step, not just at the end: the money must be accounted for
  # while it is held, not only once it has left.
  def check_ledger!
    Clearinghouse::Ledger::Invariants.check!(app_db)
  end

  def decide(decision)
    reconfigure_fake('default' => { 'decision' => decision, 'score' => 70, 'reasons' => ["spec #{decision}"] })
  end

  # A payment through the API, confirmed while RiskGate says `decision`, then
  # captured separately. Returns its id.
  def paid(amount, decision)
    decide(decision)
    id = create_intent(amount: amount, capture_method: 'manual')['id']
    expect(JSON.parse(confirm(id).body)).to include('status' => 'requires_capture')
    expect(JSON.parse(capture(id).body)).to include('status' => 'succeeded')
    check_ledger!
    id
  end

  def release_due!
    clock.advance(3 * Clearinghouse::Clock::SECONDS_PER_DAY)
    Clearinghouse::Balances::Availability.release_due!(app_db, clock: clock)
    check_ledger!
  end

  def payout!
    response = api_post('/v1/payouts')
    expect(response.status).to eq(200)
    check_ledger!
    JSON.parse(response.body)
  end

  def balances = %w[pending held available].to_h { |kind| [kind, balance(kind)] }

  def review_for(intent_id)
    get '/v1/reviews', { 'open' => 'true' }, auth
    json_body['data'].find { |r| r['payment_intent'] == intent_id }
  end

  it 'holds the reviewed money out of payouts until the review is approved' do
    allowed = paid(5_000, 'allow') # net 4,825
    reviewed = paid(10_000, 'review') # net 9,680
    review = review_for(reviewed)
    # The review shows what was captured; the money held is the merchant's net of it.
    expect([review_for(allowed), review.slice('amount', 'open', 'reason')])
      .to eq([nil, { 'amount' => 10_000, 'open' => true, 'reason' => 'spec review' }])

    seen = []
    release_due!
    seen << balances
    expect(payout!).to include('amount' => 4_825, 'status' => 'in_transit')
    seen << balances
    expect(api_post('/v1/payouts').status).to eq(400) # nothing available; held is not payable
    expect(api_post("/v1/reviews/#{review['id']}/approve").status).to eq(200)
    check_ledger!
    seen << balances
    expect(payout!).to include('amount' => 9_680)
    seen << balances

    expect(seen).to eq([{ 'pending' => 0, 'held' => 9_680, 'available' => 4_825 },
                        { 'pending' => 0, 'held' => 9_680, 'available' => 0 },
                        { 'pending' => 0, 'held' => 0, 'available' => 9_680 },
                        { 'pending' => 0, 'held' => 0, 'available' => 0 }])
    expect(AcquirerSpec.simulator.payouts.map(&:amount)).to eq([4_825, 9_680])
  end

  it 'refunds a rejected payment and releases the held money only against the refund' do
    paid(5_000, 'allow')
    reviewed = paid(10_000, 'review')
    review = review_for(reviewed)
    release_due!

    response = api_post("/v1/reviews/#{review['id']}/reject")
    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)).to include('open' => false, 'closed_reason' => 'refunded_as_fraud')
    check_ledger!
    refund = app_db[:refunds].where(payment_intent_id: reviewed).first
    expect(refund).to include(amount: 10_000, status: 'succeeded', reason: 'fraudulent')
    expect(acquirer.calls_of(:refund).map(&:last)).to eq([refund[:id]])
    # The refund takes the gross out of available and the hold puts the net back:
    # the merchant is out the fee, 320, and nothing is held any more.
    expect(balances).to eq('pending' => 0, 'held' => 0, 'available' => 4_825 - 320)

    expect(payout!).to include('amount' => 4_505)
  end

  it 'holds only what a partial capture took' do
    decide('review')
    id = create_intent(amount: 10_000, capture_method: 'manual')['id']
    confirm(id)
    capture(id, amount_to_capture: 6_000)
    expect(review_for(id)).to include('amount' => 6_000)
    release_due!
    expect(balances).to include('held' => 5_796, 'available' => 0)
  end
end
