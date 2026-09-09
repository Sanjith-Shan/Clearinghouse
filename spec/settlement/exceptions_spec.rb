# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Reconciliation::Exceptions, :db do
  include SettlementHelpers
  include DisputeHelpers
  include ReconcilerHelpers

  let(:day4) { Date.new(2026, 3, 4) }

  def resolve(id, action:, note: 'checked with the acquirer', ledger_transaction: nil)
    described_class.resolve!(app_db, id, action: action, note: note, clock: clock,
                                         ledger_transaction: ledger_transaction)
  end

  def mismatched(type, delta)
    pi, ref = captured_payment(payment_method: 'pm_card_visa')
    ingest(day4, inject: [{ type: type, acquirer_reference: ref, delta: delta }])
    [pi, exceptions(type).first.fetch(:id)]
  end

  it 'writes off money the acquirer kept, and the flow is explained again' do
    pi, id = mismatched('fee_mismatch', 3)
    resolved = resolve(id, action: 'write_off')

    expect(resolved).to have_attributes(status: 'resolved', resolution_action: 'write_off', resolved_at: clock.now,
                                        resolution_note: 'checked with the acquirer')
    expect(open_flows).to be_empty
    expect(balance_of('platform:processing_expense')).to eq(163)
    expect(app_db[:ledger_transactions].where(id: resolved.resolution_transaction_id).first)
      .to include(flow_id: pi, flow_type: 'payment', description: "write-off of fee_mismatch #{id} on #{pi}")
    expect(Clearinghouse::Ledger::Invariants.check(app_db)).to be_empty
  end

  it 'writes off an overpayment as a gain' do
    _, id = mismatched('amount_mismatch', 7)
    resolve(id, action: 'write_off')
    expect(open_flows).to be_empty
    expect(balance_of('platform:processing_expense')).to eq(160 - 7)
  end

  it 'writes off a credit-normal clearing account in the right direction' do
    pi, ref = captured_payment(payment_method: 'pm_card_visa')
    re, = refunded(pi, 4_000)
    ingest(day4, inject: [{ type: 'amount_mismatch', acquirer_reference: ref, line_type: 'refund', delta: 5 }])
    resolve(exceptions('amount_mismatch').first.fetch(:id), action: 'write_off')
    expect(open_flows).not_to have_key(re)
  end

  it 'reverses a transaction of the flow' do
    pi, id = mismatched('amount_mismatch', 7)
    settlement = app_db[:ledger_transactions].where(flow_id: pi).order(:id).last
    resolved = resolve(id, action: 'reverse', ledger_transaction: settlement[:id])
    reversal = app_db[:ledger_transactions].where(id: resolved.resolution_transaction_id).first
    expect(reversal).to include(reverses_transaction_id: settlement[:id], flow_id: pi)
    expect(open_flows).to eq(pi => { %w[platform:processor_receivable usd] => 10_000 })
  end

  it 'closes with a note only' do
    _, id = mismatched('duplicate', 1)
    expect(resolve(id, action: 'none')).to have_attributes(status: 'resolved', resolution_transaction_id: nil)
  end

  it 'refuses resolutions that cannot apply' do
    pi, id = mismatched('duplicate', 1)
    other = captured_payment(payment_method: 'pm_card_visa').first
    other_txn = app_db[:ledger_transactions].where(flow_id: other).get(:id)
    own_txn = app_db[:ledger_transactions].where(flow_id: pi).get(:id)
    invalid = described_class::InvalidResolutionError
    expect { resolve(id, action: 'write_off') }.to raise_error(invalid, /nothing stuck/)
    expect { resolve(id, action: 'reverse') }.to raise_error(invalid, /needs ledger_transaction/)
    expect { resolve(id, action: 'reverse', ledger_transaction: other_txn) }.to raise_error(invalid, /not in/)
    expect { resolve(id, action: 'none', ledger_transaction: own_txn) }.to raise_error(invalid, /only for reverse/)
    expect { resolve(id, action: 'shrug') }.to raise_error(invalid, /must be one of/)
    expect { resolve(id, action: 'none', note: '  ') }.to raise_error(invalid, /needs a note/)
    expect { resolve('rex_nope', action: 'none') }.to raise_error(described_class::NotFoundError)
    expect(exceptions.first[:status]).to eq('open')
  end

  it 'resolves once' do
    _, id = mismatched('duplicate', 1)
    resolve(id, action: 'none')
    expect { resolve(id, action: 'none') }.to raise_error(described_class::AlreadyResolvedError)
  end

  it 'turns a reversal the ledger refuses into an invalid resolution' do
    pi, id = mismatched('amount_mismatch', 7)
    first = resolve(id, action: 'write_off')
    reverse_id = Clearinghouse::Ledger.reverse!(app_db, first.resolution_transaction_id, reason: 'oops',
                                                                                         effective_at: clock.now)
    _, second = mismatched_again(pi)
    expect { resolve(second, action: 'reverse', ledger_transaction: reverse_id) }
      .to raise_error(described_class::InvalidResolutionError, /reversal/)
  end

  # A second open exception on the same flow, so a reversal can be attempted again.
  def mismatched_again(payment)
    id = described_class.create!(app_db, described_class::Draft.new(reason: 'duplicate', line_type: 'capture',
                                                                    currency: 'usd', detail: 'test', flow_id: payment),
                                 now: clock.now)
    [payment, id]
  end

  it 'lists oldest first with filters and a cursor' do
    ids = Array.new(3) do |i|
      clock.advance(60)
      described_class.create!(app_db, described_class::Draft.new(reason: i.zero? ? 'late' : 'duplicate',
                                                                 line_type: 'capture', currency: 'usd',
                                                                 detail: "n#{i}", flow_id: "pi_#{i}"),
                              now: clock.now)
    end
    page, more = described_class.list(app_db, limit: 2)
    expect([page.map(&:id), more]).to eq([ids.first(2), true])
    expect(described_class.list(app_db, limit: 5, starting_after: ids[1]).first.map(&:id)).to eq([ids[2]])
    expect(described_class.list(app_db, limit: 5, reason: 'late').first.map(&:id)).to eq([ids[0]])
    expect(described_class.list(app_db, limit: 5, flow_id: 'pi_2').first.map(&:id)).to eq([ids[2]])
    expect(described_class.list(app_db, limit: 5, status: 'resolved').first).to be_empty
    expect { described_class.list(app_db, limit: 5, starting_after: 'rex_x') }
      .to raise_error(described_class::NotFoundError)
  end
end
