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

  it 'agrees with the model after every step of random sequences over the wired endpoints' do
    report = ModelTesting::Runner.new(sut_factory: -> { sut }, sut_name: 'api', seed: 11, sequences: 6,
                                      max_length: 30).run
    expect(report.failure).to be_nil, -> { report.failure.script }
    expect(report.stats.by_outcome.keys).to include('confirm ok', 'confirm card_declined', 'refund ok')
    expect(report.stats.by_operation.keys).not_to include('payout', 'settle', 'resolve_dispute')
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

  it 'leaves the operations of areas that have not landed as clear TODOs' do
    expect(sut.unsupported_operations).to contain_exactly(:payout, :availability_sweep, :resolve_dispute, :settle)
    expect { sut.payout(payout: 'po_1', merchant: 'm1', currency: 'usd') }
      .to raise_error(NotImplementedError, %r{TODO\(payouts\): POST /v1/payouts})
    expect { sut.settle }.to raise_error(NotImplementedError, /TODO\(reconciler\)/)
    expect { sut.resolve_dispute(intent: 'pi_1', outcome: 'won') }.to raise_error(NotImplementedError, /disputes/)
    expect { sut.availability_sweep }.to raise_error(NotImplementedError, /availability worker/)
  end
end
