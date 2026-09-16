# typed: false
# frozen_string_literal: true

# RiskGate in confirm, end to end: the real confirm flow, the real risk client
# against the fake RiskGate over real sockets, and the real acquirer simulator.
RSpec.describe 'RiskGate during confirm', :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'
  include FakeRiskgateHelper

  let(:risk_client) { Clearinghouse::Risk::Client.new(base_url: riskgate_url, deadline_ms: 2_000) }
  let(:deps) do
    Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock, log: log, admin_token: 'admin_spec_token',
                                         acquirer: acquirer, risk_client: risk_client)
  end

  def decide(decision, score: 50)
    reconfigure_fake('default' => { 'decision' => decision, 'score' => score, 'reasons' => ["spec #{decision}"] })
  end

  def assessments = fake_riskgate.stats.fetch('assessments', 0)

  it 'blocks a payment before the acquirer or the ledger hear of it' do
    decide('block', score: 97)
    id = create_intent(risk_fields: { email_domain: 'example.com' })['id']
    response = confirm(id, {}, 'HTTP_IDEMPOTENCY_KEY' => 'k1')
    expect(response.status).to eq(402)
    expect(json_body['error']).to include('type' => 'risk_error', 'code' => 'payment_blocked')
    row = intent_row(id)
    expect([row[:status], row[:payment_method]]).to eq(['requires_payment_method', nil])
    expect(JSON.parse(row[:risk])).to include('decision' => 'block', 'score' => 97)
    expect(JSON.parse(row[:last_payment_error])).to include('code' => 'payment_blocked')
    expect([AcquirerSpec.simulator.operations, acquirer.calls, ApiSpecHelpers.db[:ledger_transactions].count])
      .to eq([[], [], 0])
    expect(event_types(id)).to eq(%w[payment_intent.created payment_intent.payment_failed])
    # The block is the answer to that request: it replays.
    expect([confirm(id, {}, 'HTTP_IDEMPOTENCY_KEY' => 'k1').body, assessments]).to eq([response.body, 1])
  end

  it 'stores an allow on the intent and proceeds' do
    decide('allow', score: 3)
    id = create_intent['id']
    body = JSON.parse(confirm(id).body)
    expect(body).to include('status' => 'succeeded')
    expect(body['risk']).to include('decision' => 'allow', 'score' => 3, 'reasons' => ['spec allow'])
    expect(ApiSpecHelpers.db[:risk_holds].count).to eq(0)
  end

  it 'lets a review through and holds the payout of what was captured' do
    decide('review', score: 71)
    id = create_intent(amount: 5000, capture_method: 'manual')['id']
    confirm(id)
    expect(ApiSpecHelpers.db[:risk_holds].count).to eq(0) # nothing to hold until money moves
    capture(id, amount_to_capture: 3000)
    hold = Clearinghouse::Balances::Holds.find(ApiSpecHelpers.db, flow_id: id)
    expect([hold.merchant_id, hold.amount.amount, hold.reason, hold.open?])
      .to eq([merchant.id, 3000, 'spec review', true])
  end

  it 'fails open when RiskGate errors, and says so on the intent' do
    reconfigure_fake('error_rate' => 1.0, 'error_status' => 500)
    id = create_intent['id']
    body = JSON.parse(confirm(id).body)
    expect(body['status']).to eq('succeeded')
    expect(body['risk']).to include('decision' => 'risk_unavailable', 'reason' => 'http_status')
  end

  it 'does not ask RiskGate again when a confirm resumes past risk_assessed' do
    decide('allow')
    id = create_intent['id']
    acquirer.fail_next(:authorize, :drop)
    expect(confirm(id, {}, 'HTTP_IDEMPOTENCY_KEY' => 'k1').status).to eq(503)
    expect(confirm(id, {}, 'HTTP_IDEMPOTENCY_KEY' => 'k1').status).to eq(200)
    expect(assessments).to eq(1)
  end

  it 'asks again, as a new attempt with a new RiskGate key, when the merchant confirms again after a block' do
    decide('block')
    id = create_intent['id']
    confirm(id)
    decide('allow')
    expect(JSON.parse(confirm(id, payment_method: 'pm_card_visa').body)['status']).to eq('succeeded')
    expect(fake_riskgate.assessment_id_for("#{id}:2")).not_to be_nil
    expect(assessments).to eq(2)
  end
end
