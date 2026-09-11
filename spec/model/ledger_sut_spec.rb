# typed: false
# frozen_string_literal: true

require_relative 'model_helper'

# Experiment 4 in CI: random sequences through the real ledger on real Postgres,
# every invariant checked after every step. bin/model-test runs the big ones.
RSpec.describe Clearinghouse::Testing::Model::LedgerSut, :db, :model do
  def ledger_sut(**args)
    described_class.new(db: app_db, owner_db: owner_db, **args)
  end

  def runner(sut, seed:, sequences:, max_length:, plant: nil)
    ModelTesting::Runner.new(sut_factory: -> { sut }, sut_name: 'ledger', seed: seed, sequences: sequences,
                             max_length: max_length, plant: plant)
  end

  it 'agrees with the model after every step of random sequences, with every invariant holding' do
    report = runner(ledger_sut, seed: 7, sequences: 12, max_length: 40).run
    expect(report.failure).to be_nil, -> { report.failure.script }
    expect(report.stats.operations).to be >= 12 * 20
    expect(report.stats.by_event.keys).to include('capture', 'settlement', 'funds_available', 'refund',
                                                  'refund_settled', 'payout', 'dispute_opened')
  end

  it 'posts every row of the money-flow table through Ledger::Flows and ends explained' do
    session = ModelTesting::Session.new(ledger_sut)
    steps = [merchant_cmd, intent_cmd('pi_1', 10_000),
             cmd(:confirm, intent: 'pi_1', payment_method: 'pm_card_disputeFraudulent'),
             cmd(:refund, refund: 're_1', intent: 'pi_1', amount: 4000),
             cmd(:advance_clock, hours: 48), cmd(:settle), cmd(:availability_sweep),
             cmd(:payout, payout: 'po_1', merchant: 'm1', currency: 'usd', amount: 1013),
             cmd(:payout, payout: 'po_2', merchant: 'm1', currency: 'usd', amount: 1000),
             cmd(:advance_clock, hours: 5 * 24), cmd(:resolve_dispute, intent: 'pi_1', outcome: 'won'),
             cmd(:advance_clock, hours: 48), cmd(:settle)]
    steps.each { |c| expect(session.step(c).violation).to be_nil, c.to_ruby }
    expect(Clearinghouse::Ledger::Clearing.report(app_db, as_of: Time.utc(2027), slas: {}).open_flows).to be_empty
    kinds = app_db[:ledger_transactions].select_map(:description).uniq
    expect(kinds).to contain_exactly('capture', 'refund', 'settlement', 'refund settled', 'funds available',
                                     'payout', 'payout paid', 'payout failed', 'dispute opened',
                                     'dispute debited', 'dispute won', 'dispute funds returned')
  end

  it 'reports the same balances Ledger.balance does' do
    sut = ledger_sut
    session = ModelTesting::Session.new(sut)
    [merchant_cmd, intent_cmd('pi_1', 2500), cmd(:confirm, intent: 'pi_1', payment_method: 'pm_card_visa')]
      .each { |c| session.step(c) }
    snapshot = sut.snapshot
    expect(snapshot.balances).not_to be_empty
    snapshot.balances.each do |(code, currency), balance|
      expect(Clearinghouse::Ledger.balance(app_db, code, currency).amount).to eq(balance)
    end
  end

  it 'decides payouts from the real balance, not the model' do
    sut = ledger_sut
    session = ModelTesting::Session.new(sut)
    [merchant_cmd, intent_cmd('pi_1', 2500), cmd(:confirm, intent: 'pi_1', payment_method: 'pm_card_visa'),
     cmd(:advance_clock, hours: 48), cmd(:availability_sweep)].each { |c| session.step(c) }
    # Money the model knows nothing about: the adapter must see it and pay it out.
    Clearinghouse::Ledger.post!(app_db, flow_type: 'payout', flow_id: 'po_9', description: 'seeded',
                                        effective_at: Time.utc(2026, 1, 3),
                                        entries: Clearinghouse::Ledger::Flows.payout_failed(
                                          merchant_id: 'm1', amount: Clearinghouse::Money.of(100, 'usd')
                                        ))
    step = session.step(cmd(:payout, payout: 'po_1', merchant: 'm1', currency: 'usd'))
    expect(step.expected.fields['amount']).to eq(2398)
    expect(step.actual.fields['amount']).to eq(2498)
    expect(step.violation.check).to eq(:outcome)
  end

  it 'catches the planted fee rounding bug and shrinks it to one $5.00-style payment' do
    found = runner(ledger_sut(**ModelTesting::PlantedBugs.ledger_sut_args('fee_rounding')),
                   seed: 1, sequences: 40, max_length: 40, plant: 'fee_rounding').run.failure
    expect(found.shrunk_failure.violation.check).to eq(:balances)
    expect(found.shrunk.map(&:op)).to eq(%i[create_merchant create_intent confirm])
    expect(found.shrunk[1].args[:amount] % 500).to eq(0)
    expect(found.shrunk_failure.violation.details).to include(a_string_matching(/platform:fee_revenue.*off by 1/))
  end

  it 'catches a flow that skips its clearing account' do
    sut = ledger_sut(**ModelTesting::PlantedBugs.ledger_sut_args('payout_failed_skips_clearing'))
    commands = [merchant_cmd, intent_cmd('pi_1', 5000), cmd(:confirm, intent: 'pi_1', payment_method: 'pm_card_visa'),
                cmd(:advance_clock, hours: 48), cmd(:availability_sweep),
                cmd(:payout, payout: 'po_1', merchant: 'm1', currency: 'usd', amount: 1013),
                cmd(:advance_clock, hours: 24)]
    failure = ModelTesting::Session.first_failure(sut, commands)
    expect(failure.index).to eq(6)
    expect(failure.violation.details)
      .to include(a_string_matching(/platform:payout_clearing \(usd\): model 0, system 1013/))
  end

  it 'reports a real ledger violation through the ledger_invariants check' do
    sut = ledger_sut
    session = ModelTesting::Session.new(sut)
    [merchant_cmd, intent_cmd('pi_1', 2500)].each { |c| session.step(c) }
    session.step(cmd(:confirm, intent: 'pi_1', payment_method: 'pm_card_visa'))
    owner_db[:account_balances].where(account_id: app_db[:ledger_accounts].where(code: 'platform:fee_revenue')
                                                                          .get(:id)).update(balance: 0)
    expect(sut.snapshot.ledger_violations).to include(a_string_matching(/balances_match_entries: platform:fee_revenue/))
  end

  it 'refuses to empty a database that is not a test database' do
    db = Sequel.mock(fetch: { current_database: 'clearinghouse_dev' })
    expect { ModelTesting::DbReset.ledger!(db) }.to raise_error(ModelTesting::DbReset::RefusedError)
  end
end
