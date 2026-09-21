# typed: false
# frozen_string_literal: true

require 'tempfile'
require_relative '../../sim/experiments/replay'

# Experiment 8's driver, end to end on five invented rows: the real API, acquirer
# simulator, scheduler and webhook workers in this process, the fake RiskGate over real
# sockets. The rows are hand-written in the export's shape and come from no data file.
# Each policy runs once (memoized); the examples check what that run left behind,
# which `inspect` captured before the stack stopped.
module ReplaySpec
  SECRET = 'whsec_exp8_spec_not_a_secret'
  FAKE = { 'ruleset_version' => 'fake-spec', 'webhook_secrets' => [SECRET],
           'rules' => [
             { 'name' => 'big', 'amount_gte' => 90_000, 'decision' => 'block', 'score' => 95, 'reasons' => ['big'] },
             { 'name' => 'flagged', 'risk_fields' => { 'product_code' => 'R' }, 'decision' => 'review',
               'score' => 60, 'reasons' => ['flagged'] }
           ] }.freeze
  # 2023-11-14 22:13:20 UTC, so the rows cross a simulated midnight and the
  # scheduler ticks during the replay as well as after it.
  T0 = 1_700_000_000

  def self.row(index, offset, amount, fraud, fields = {})
    Experiments::Replay::Row.new(index: index, created: T0 + offset, amount: amount, currency: 'usd',
                                 risk_fields: fields, fraud: fraud)
  end

  ROWS = [row(0, 0, 2_000, false, 'product_code' => 'W', 'card4' => 'visa'), # allowed
          row(1, 600, 3_100, true, 'product_code' => 'W'),                     # fraud that gets through
          row(2, 1_200, 95_000, true),                                         # fraud, blocked
          row(3, 3_600, 120_000, false),                                       # legitimate, blocked
          row(4, 7_200, 4_500, false, 'product_code' => 'R')].freeze           # reviewed

  Run = Struct.new(:report, :records, :blocked, :hold, :webhooks, :assessed, keyword_init: true)

  def self.model_rules = @model_rules ||= run('model_rules')
  def self.none = @none ||= run('none')

  def self.run(policy)
    DBHelper.clean!
    fake = FakeRiskgate::Server.new(config: FakeRiskgate::Config.new(FAKE.dup)).start
    db = DBHelper.app
    captured = {}
    plan = Experiments::Replay::Plan.new(policy: policy, seed: 3, webhook_secret: SECRET, webhook_drain_seconds: 30.0,
                                         deadline_ms: 2_000)
    url = policy == 'none' ? nil : "http://127.0.0.1:#{fake.port}"
    report = Experiments::Replay::Runner.new(db: db, plan: plan, riskgate_url: url, log: nil)
                                        .run(ROWS, inspect: lambda { |stack, _merchant, records|
                                          captured.merge!(capture(db, stack, records))
                                        })
    Run.new(report: report, webhooks: fake.webhooks,
            assessed: fake.requests.select { |r| r.path == '/v1/assess' }.map { |r| JSON.parse(r.body) },
            **captured)
  ensure
    fake&.stop
  end

  def self.capture(db, stack, records)
    authorized = stack.simulator.authorizations.map(&:reference)
    blocked = records.select { |r| r.outcome == 'blocked' }.map do |r|
      { code: r.code, authorized: authorized.include?(r.intent_id),
        ledger_transactions: db[:ledger_transactions].where(flow_id: r.intent_id).count,
        status: db[:payment_intents].where(id: r.intent_id).get(:status) }
    end
    review = records.find { |r| r.outcome == 'review' }
    { records: records, blocked: blocked,
      hold: review && Clearinghouse::Balances::Holds.find(db, flow_id: review.intent_id) }
  end
end

RSpec.describe 'Experiment 8: the replay through Clearinghouse and RiskGate' do
  let(:replay) { Experiments::Replay }

  context 'with model and rules (the fake RiskGate blocking large amounts and reviewing product R)' do
    let(:run) { ReplaySpec.model_rules }
    let(:money) { run.report.fetch('money') }

    it 'decides each row as the rules say' do
      expect(run.records.map(&:outcome)).to eq(%w[approved approved blocked blocked review])
    end

    it 'posts nothing for a block and never reaches the acquirer' do
      expect(run.blocked).to eq([{ code: 'payment_blocked', authorized: false, ledger_transactions: 0,
                                   status: 'requires_payment_method' }] * 2)
    end

    it "captures a review and holds its funds through the replayed week's availability sweeps" do
      expect(run.hold.amount).to eq(Clearinghouse::Money.of(4_500, 'usd'))
      expect(run.hold.closed_at).to be_nil
      expect(run.hold.held_amount).to be_positive
      expect(run.report.fetch('holds')).to include('opened' => 1, 'open' => 1, 'amount_cents' => 4_500)
    end

    it 'disputes the fraud that got through once the window passes, and nothing else' do
      expect(money.fetch('disputes')).to include('count' => 1, 'volume_cents' => 3_100, 'on_legit_rows' => 0)
      expect(run.report.fetch('disputes_in_simulator')).to eq('count' => 1, 'volume_cents' => 3_100)
      expect(run.report.fetch('disputes_source')).to eq('clearinghouse (GET /v1/disputes)')
    end

    it 'adds up the money' do
      expect(money.values_at('approved', 'blocked', 'reviews', 'fraud_caught', 'legit_blocked')).to eq(
        [{ 'count' => 3, 'volume_cents' => 2_000 + 3_100 + 4_500 }, { 'count' => 2, 'volume_cents' => 215_000 },
         { 'count' => 1, 'volume_cents' => 4_500 }, { 'count' => 1, 'volume_cents' => 95_000 },
         { 'count' => 1, 'volume_cents' => 120_000 }]
      )
      expect(money.fetch('dispute_losses_cents')).to eq(3_100 + 1_500)
      # Saved: the blocked fraud and the assumed fee its dispute would have cost.
      # Cost: the legitimate payment blocked.
      expect(money.fetch('net')).to eq('saved_cents' => 95_000 + 1_500, 'cost_cents' => 120_000,
                                       'net_cents' => 95_000 + 1_500 - 120_000)
    end

    it 'times the risk step inside every confirm and leaves the ledger consistent' do
      expect(run.report.dig('latency', 'risk_step_ms', 'n')).to eq(5)
      expect(run.report.dig('riskgate', 'ruleset_versions_seen')).to eq('fake-spec' => 3)
      expect(run.report.fetch('scheduler_step_errors')).to be_empty
      expect(run.report.fetch('ledger_invariant_violations')).to eq(0)
    end

    it 'sends RiskGate each row at its own time with its risk_fields exactly as given' do
      expect(run.assessed.map { |a| a['created'] }).to eq(ReplaySpec::ROWS.map(&:created))
      expect(run.assessed.map { |a| a['risk_fields'] }).to eq(ReplaySpec::ROWS.map(&:risk_fields))
    end

    it 'delivers labels back to RiskGate over signed webhooks' do
      expect(run.report.fetch('webhooks')).to include('registered' => true, 'workers_ran' => true, 'drained' => true)
      expect(run.webhooks).to include('rejected' => 0)
      expect(run.webhooks.dig('by_type', 'payment_intent.succeeded')).to eq(3)
      expect(run.webhooks.dig('by_type', 'charge.dispute.created')).to eq(1)
    end
  end

  context 'with no checks' do
    let(:run) { ReplaySpec.none }
    let(:money) { run.report.fetch('money') }

    it 'never asks RiskGate and lets every payment through' do
      expect(run.records.map(&:outcome)).to all(eq('unchecked'))
      expect(run.assessed).to be_empty
      expect(money.fetch('approved')).to eq('count' => 5, 'volume_cents' => ReplaySpec::ROWS.sum(&:amount))
      expect(run.report.dig('webhooks', 'registered')).to be(false)
    end

    it 'turns every fraud row into a dispute and saves nothing' do
      expect(money.fetch('disputes')).to include('count' => 2, 'volume_cents' => 3_100 + 95_000)
      expect(money.fetch('dispute_losses_cents')).to eq(3_100 + 95_000 + (2 * 1_500))
      expect(money.fetch('net')).to eq('saved_cents' => 0, 'cost_cents' => 0, 'net_cents' => 0)
    end
  end

  describe 'the arithmetic' do
    def record(outcome, amount, fraud: false, intent: nil, confirm_ms: nil, risk_ms: nil)
      Experiments::Replay::Record.new(fraud: fraud, amount: amount, outcome: outcome, intent_id: intent,
                                      confirm_ms: confirm_ms, risk_ms: risk_ms)
    end

    it 'counts each outcome once and nets saved against cost with the assumed fee' do
      records = [record('approved', 1_000, intent: 'pi_a'), record('review', 2_000, fraud: true, intent: 'pi_b'),
                 record('risk_unavailable', 3_000, fraud: true, intent: 'pi_c'),
                 record('blocked', 4_000, fraud: true, intent: 'pi_d'), record('blocked', 5_000, intent: 'pi_e'),
                 record('declined', 6_000, intent: 'pi_f')]
      disputes = [Experiments::Replay::Dispute.new(intent_id: 'pi_b', amount: 2_000),
                  Experiments::Replay::Dispute.new(intent_id: 'pi_c', amount: 3_000)]
      money = replay.money(records, disputes: disputes, fee_cents: 1_500)

      expect(money.values_at('approved', 'fraud_through', 'declined_or_error')).to eq(
        [{ 'count' => 3, 'volume_cents' => 6_000 }, { 'count' => 2, 'volume_cents' => 5_000 },
         { 'count' => 1, 'volume_cents' => 6_000 }]
      )
      expect(money['disputes']).to eq('count' => 2, 'volume_cents' => 5_000, 'on_legit_rows' => 0,
                                      'on_unknown_payments' => 0)
      expect(money['dispute_losses_cents']).to eq(5_000 + 3_000)
      expect(money['net']).to eq('saved_cents' => 5_500, 'cost_cents' => 5_000, 'net_cents' => 500)
      expect(money['outcomes'].values.sum).to eq(6)
    end

    it 'takes nearest-rank percentiles and the risk share over confirms that called RiskGate' do
      records = Array.new(100) { |i| record('approved', 1, confirm_ms: (i + 1).to_f, risk_ms: 0.25 * (i + 1)) }
      records << record('unchecked', 1, confirm_ms: 1_000.0)
      latency = replay.latency(records)
      expect(latency['confirm_ms']).to include('n' => 101, 'p50' => 51.0, 'p99' => 100.0, 'max' => 1_000.0)
      expect(latency['risk_step_ms']).to include('n' => 100, 'p50' => 12.5, 'p99' => 24.75)
      expect(latency['risk_share_of_confirm']).to eq(0.25)
    end

    it 'formats cents as dollars' do
      expect([replay.usd(0), replay.usd(123_456_789), replay.usd(-2_350)]).to eq(['$0.00', '$1,234,567.89', '-$23.50'])
    end
  end

  describe 'reading the export' do
    let(:row_class) { Experiments::Replay::Row }

    it 'keeps risk_fields exactly as read and picks the card from the label' do
      row = row_class.parse('{"payment_id":"x1","created":5,"amount":250,"currency":"USD",' \
                            '"risk_fields":{"a":null,"b":1.5,"c":"s"},"is_fraud":1}', 0)
      expect(row.risk_fields).to eq('a' => nil, 'b' => 1.5, 'c' => 's')
      expect([row.currency, row.fraud, row.payment_method]).to eq(['usd', true, 'pm_card_disputeFraudulent'])
    end

    it 'refuses a line without every key or with a label that is not 0 or 1' do
      expect { row_class.parse('{"created":5}', 2) }.to raise_error(row_class::MalformedError, /line 3/)
      expect do
        row_class.parse('{"payment_id":"x","created":5,"amount":1,"currency":"usd","risk_fields":{},' \
                        '"is_fraud":2}', 0)
      end.to raise_error(row_class::MalformedError, /is_fraud/)
    end

    it 'streams at most the limit' do
      Tempfile.create(['replay', '.jsonl']) do |file|
        3.times do |i|
          file.puts(JSON.generate('payment_id' => "x#{i}", 'created' => i, 'amount' => 100 + i, 'currency' => 'usd',
                                  'risk_fields' => {}, 'is_fraud' => 0))
        end
        file.flush
        expect(replay.read(file.path, limit: 2).map(&:amount)).to eq([100, 101])
      end
    end
  end
end
