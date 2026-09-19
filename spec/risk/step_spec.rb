# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Risk::Step do
  include FakeRiskgateHelper

  let(:fake_config) do
    { 'rules' => [
      { 'name' => 'huge', 'amount_gte' => 1_000_000, 'decision' => 'block', 'score' => 96, 'reasons' => ['big'] },
      { 'name' => 'odd', 'risk_fields' => { 'DeviceType' => 'odd' }, 'decision' => 'review', 'score' => 66,
        'reasons' => ['odd device'] }
    ] }
  end
  let(:client) { Clearinghouse::Risk::Client.new(base_url: riskgate_url, deadline_ms: 200) }
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 3, 1)) }
  let(:created_at) { Time.utc(2026, 2, 28, 23, 59, 0) }

  after { client.close }

  def intent(amount: 5_000, risk_fields: {}, id: 'pi_000000000000000000000001')
    { id: id, amount: amount, currency: 'usd', created_at: created_at, risk_fields: risk_fields }
  end

  def step(attrs, attempt: 1)
    described_class.call(attrs, attempt: attempt, clock: clock, client: client)
  end

  it 'sends the intent as RiskGate expects it: event time from created_at, risk_fields verbatim' do
    step(intent(risk_fields: { 'DeviceType' => 'desktop', 'P_emaildomain' => nil }), attempt: 2)
    request = fake_riskgate.requests.last

    expect(JSON.parse(request.body)).to eq('payment_id' => 'pi_000000000000000000000001', 'created' => created_at.to_i,
                                           'amount' => 5_000, 'currency' => 'usd',
                                           'risk_fields' => { 'DeviceType' => 'desktop', 'P_emaildomain' => nil })
    expect(request.headers['idempotency-key']).to eq('pi_000000000000000000000001:2')
  end

  it 'proceeds on allow and produces the risk column' do
    outcome = step(intent)
    expect(outcome.verdict).to have_attributes(proceed?: true, hold: false)
    expect(outcome.verdict.risk).to include('decision' => 'allow', 'score' => 5, 'ruleset_version' => 'fake-1')
    expect(outcome.verdict.risk['assessment_id']).to start_with('asm_')
    expect(outcome.assessed_at).to eq(clock.now)
    expect(outcome.elapsed_ms).to be_between(0, 200)
  end

  it 'proceeds with a hold on review' do
    outcome = step(intent(risk_fields: { 'DeviceType' => 'odd' }))
    expect(outcome.verdict).to have_attributes(proceed?: true, hold: true)
  end

  it 'blocks with the typed error on block' do
    outcome = step(intent(amount: 2_000_000))
    expect(outcome.verdict).to have_attributes(proceed?: false)
    expect(outcome.verdict.error.code).to eq('payment_blocked')
  end

  it 'fails open, inside the deadline, when RiskGate hangs' do
    reconfigure_fake('hang' => true)
    outcome = step(intent)
    expect(outcome.verdict).to have_attributes(proceed?: true, hold: false, checked?: false)
    expect(outcome.verdict.risk).to eq('decision' => 'risk_unavailable', 'reason' => 'timeout')
    expect(outcome.elapsed_ms).to be < 200 + 40
  end

  it 'fails open when RiskGate is not there at all' do
    down = Clearinghouse::Risk::Client.new(base_url: "http://127.0.0.1:#{FakeRiskgateHelper.closed_port}")
    outcome = described_class.call(intent, attempt: 1, clock: clock, client: down)
    expect(outcome.verdict.risk).to eq('decision' => 'risk_unavailable', 'reason' => 'connection')
  end

  it 'gets the same decision back on a crash-resume, without a second assessment' do
    first = step(intent(risk_fields: { 'DeviceType' => 'odd' }))
    # The process died before the next phase committed; the completer resumes at
    # intent_locked and runs the step again for the same attempt.
    resumed = step(intent(risk_fields: { 'DeviceType' => 'odd' }))

    expect(resumed.verdict.risk).to eq(first.verdict.risk)
    expect(resumed.result.replayed).to be(true)
    expect(fake_riskgate.stats['assessments']).to eq(1)
  end

  it 'uses the process-wide client by default' do
    Clearinghouse::Risk.client = client
    expect(described_class.call(intent, attempt: 1, clock: clock).verdict.proceed?).to be(true)
  ensure
    Clearinghouse::Risk.client = nil
  end

  describe '.hold_on_capture!' do
    let(:holds) { RiskHoldsStandIn.new }
    let(:db) { Object.new }

    def hold(risk, amount: 3_000)
      described_class.hold_on_capture!(db, risk: risk, merchant_id: 'acct_1', payment_intent_id: 'pi_1',
                                           amount_captured: Clearinghouse::Money.of(amount, 'usd'), clock: clock,
                                           holds: holds)
    end

    it 'holds exactly the captured amount of a reviewed payment, in the caller\'s transaction' do
      expect(hold({ 'decision' => 'review' })).to eq(Clearinghouse::Money.of(3_000, 'usd'))
      expect(holds.holds.map(&:to_h)).to eq([{ db: db, merchant_id: 'acct_1', payment_intent_id: 'pi_1',
                                               amount: Clearinghouse::Money.of(3_000, 'usd'),
                                               reason: 'risk_review', at: clock.now }])
    end

    it "shows RiskGate's reasons for the review as the hold's reason" do
      hold({ 'decision' => 'review', 'reasons' => ['velocity: 5 cards in 1h', 'new device'] })
      expect(holds.holds.map(&:reason)).to eq(['velocity: 5 cards in 1h; new device'])
    end

    it 'holds nothing for allow, risk_unavailable, no assessment, or a zero capture' do
      [{ 'decision' => 'allow' }, { 'decision' => 'risk_unavailable', 'reason' => 'timeout' }, nil].each do |risk|
        expect(hold(risk)).to be_nil
      end
      expect(hold({ 'decision' => 'review' }, amount: 0)).to be_nil
      expect(holds.holds).to be_empty
    end

    it 'refuses to let a review pass silently while no holds backend is wired' do
      expect do
        described_class.hold_on_capture!(db, risk: { 'decision' => 'review' }, merchant_id: 'acct_1',
                                             payment_intent_id: 'pi_1', clock: clock,
                                             amount_captured: Clearinghouse::Money.of(1, 'usd'),
                                             holds: Clearinghouse::Risk::Holds::Unwired.new)
      end.to raise_error(Clearinghouse::Risk::Holds::NotWired)
    end

    it 'forwards to Balances::Holds in its own argument names through Delegate' do
      calls = []
      target = Class.new { define_method(:open_hold!) { |*args, **kwargs| calls << [args, kwargs] } }.new
      Clearinghouse::Risk::Holds::Delegate.new(target)
                                          .open_hold!(db, merchant_id: 'acct_1', payment_intent_id: 'pi_1',
                                                          amount: Clearinghouse::Money.of(5, 'usd'),
                                                          reason: 'risk_review', clock: clock)
      expect(calls).to eq([[[db], { flow_id: 'pi_1', merchant_id: 'acct_1', amount: Clearinghouse::Money.of(5, 'usd'),
                                    reason: 'risk_review', clock: clock }]])
    end
  end
end
