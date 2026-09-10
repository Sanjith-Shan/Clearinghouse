# typed: false
# frozen_string_literal: true

require_relative '../../sim/experiments/risk_failure'

# A short experiment 9 run against bin/fake-riskgate as a real subprocess: the
# runner has to see the fault, fail open through it, and recover.
RSpec.describe 'Experiment 9 runner' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:port) { FakeRiskgateHelper.closed_port }
  let(:target) do
    Experiments::RiskFailure::Target.new(
      label: 'fake-riskgate', url: "http://127.0.0.1:#{port}", dir: root,
      argv: [RbConfig.ruby, Experiments::RiskFailure::FAKE_SCRIPT, '--port', port.to_s]
    )
  end
  let(:requests) do
    lambda do |i|
      Clearinghouse::Risk::AssessRequest.new(payment_id: "pi_spec_#{i}", created: 1_767_225_600,
                                             amount: Clearinghouse::Money.of(1_000, 'usd'))
    end
  end

  after { target.stop }

  it 'fails open through a frozen RiskGate with the step bounded by the deadline, then recovers' do
    plan = Experiments::RiskFailure::Plan.new(rate: 100.0, healthy: 0.5, down: 1.0, after: 2.5, mode: 'freeze',
                                              deadline_ms: 50, workers: 16)
    target.start
    report = Experiments::RiskFailure::Runner.new(target: target, plan: plan, requests: requests, log: nil).run

    expect(report.values_at('calls', 'completed')).to eq([400, 400])
    expect(report['unchecked']).to be_between(20, 399)
    expect(report['phases']['down_breaker_closed']['reasons'].keys).to eq(['timeout'])
    expect(report['phases']['down_breaker_closed']['service_ms']['max']).to be < 50 + 40
    expect(report['phases']['breaker_open']['reasons']).to include('breaker_open')
    expect(report['breaker_transitions'].map { |t| t['to'] }).to include('open', 'closed')
    expect(report['phases']['healthy_after']['unchecked']).to eq(0)
    expect(Experiments::RiskFailure.summary(report)).to include('went through unchecked', '| down_breaker_closed |')
  end
end
