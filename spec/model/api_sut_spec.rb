# typed: false
# frozen_string_literal: true

require_relative 'model_helper'
require_relative '../support/acquirer'

# The model against the whole API: HTTP through the Rack app, the payments
# services, the ledger, and the real acquirer simulator over TCP.
RSpec.describe Clearinghouse::Testing::Model::ApiSut, :db, :model do
  let(:sut) do
    described_class.new(db: app_db, owner_db: owner_db, acquirer_url: AcquirerSpec.server.url,
                        reset_acquirer: -> { AcquirerSpec.simulator.reset! })
  end

  it 'agrees with the model after every step of random sequences over every operation' do
    report = ModelTesting::Runner.new(sut_factory: -> { sut }, sut_name: 'api', seed: 11, sequences: 6,
                                      max_length: 60).run
    expect(report.failure).to be_nil, -> { report.failure.script }
    expect(report.stats.by_outcome.keys).to include('confirm ok', 'confirm card_declined', 'refund ok', 'payout ok',
                                                    'settle ok', 'availability_sweep ok')
    expect(report.stats.by_event.keys).to include('settlement', 'funds_available', 'payout')
  end

  def run_steps(session, steps)
    steps.map do |c|
      step = session.step(c)
      expect(step.violation).to be_nil, -> { "#{c.to_ruby}: #{step.violation&.details}" }
      step.actual
    end
  end

  it 'opens a dispute through the poller, fails a refund the acquirer refuses, and clears once settled' do
    session = ModelTesting::Session.new(sut)
    run_steps(session, [merchant_cmd, intent_cmd('pi_1', 10_000),
                        cmd(:confirm, intent: 'pi_1', payment_method: 'pm_card_disputeFraudulent'),
                        cmd(:advance_clock, hours: 48), cmd(:availability_sweep), cmd(:advance_clock, hours: 120)])
    expect(sut.snapshot.balances).to include(%w[merchant:m1:available usd] => 9680 - 11_500,
                                             %w[platform:dispute_clearing usd] => 10_000)
    refund, resolved = run_steps(session, [cmd(:refund, refund: 're_1', intent: 'pi_1', amount: 100),
                                           cmd(:resolve_dispute, intent: 'pi_1', outcome: 'won')])
    expect(refund).to eq(success(amount: 100, status: 'failed'))
    expect(resolved).to eq(success(status: 'won'))
    run_steps(session, [cmd(:advance_clock, hours: 72), cmd(:settle)])
    expect(sut.snapshot.open_flows).to eq({})
    expect(sut.snapshot.balances).to include(%w[platform:dispute_fee_revenue usd] => 1500)
  end

  it 'pays out in transit, and applies the bank\'s paid and failed answers from the feed' do
    session = ModelTesting::Session.new(sut)
    outcomes = run_steps(session, [merchant_cmd, intent_cmd('pi_1', 10_000),
                                   cmd(:confirm, intent: 'pi_1', payment_method: 'pm_card_visa'),
                                   cmd(:advance_clock, hours: 48), cmd(:availability_sweep),
                                   cmd(:payout, payout: 'po_1', merchant: 'm1', currency: 'usd', amount: 1013),
                                   cmd(:payout, payout: 'po_2', merchant: 'm1', currency: 'usd', amount: 5000),
                                   cmd(:advance_clock, hours: 24)])
    expect(outcomes[5..6]).to eq([success(amount: 1013, status: 'in_transit'),
                                  success(amount: 5000, status: 'in_transit')])
    expect(sut.snapshot.balances).to include(%w[merchant:m1:available usd] => 9680 - 5000,
                                             %w[platform:cash usd] => -5000)
  end

  it 'reports balances and flows under the sequence names, not the API ids' do
    session = ModelTesting::Session.new(sut)
    steps = [merchant_cmd, intent_cmd('pi_1', 2000),
             cmd(:confirm, intent: 'pi_1', payment_method: 'pm_card_visa'),
             cmd(:refund, refund: 're_1', intent: 'pi_1', amount: 500)]
    steps.each { |c| expect(session.step(c).violation).to be_nil, c.to_ruby }
    snapshot = sut.snapshot
    expect(snapshot.balances).to include(%w[merchant:m1:pending usd] => 1912, %w[merchant:m1:available usd] => -500)
    expect(snapshot.open_flows.keys).to contain_exactly('pi_1', 're_1')
    expect(snapshot.intents.transform_values(&:serialize)).to eq('pi_1' => { 'captured' => 2000, 'refunded' => 500 })
  end

  it 'expires an authorization when the clock passes its TTL, as the model does' do
    session = ModelTesting::Session.new(sut)
    [merchant_cmd, intent_cmd('pi_1', 2000, capture_method: 'manual'),
     cmd(:confirm, intent: 'pi_1', payment_method: 'pm_card_visa'), cmd(:advance_clock, hours: 7 * 24),
     cmd(:capture, intent: 'pi_1')].each { |c| expect(session.step(c).violation).to be_nil, c.to_ruby }
    expect(sut.capture(intent: 'pi_1').code).to eq('payment_intent_unexpected_state')
  end

  it 'runs every operation, and every card but pm_card_timeout' do
    expect(sut.unsupported_operations).to eq([])
    expect(sut.unsupported_payment_methods).to eq(%w[pm_card_timeout])
  end
end
