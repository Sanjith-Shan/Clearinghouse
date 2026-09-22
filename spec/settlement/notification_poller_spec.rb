# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Acquirer::NotificationPoller, :db do
  include SettlementHelpers

  let(:seen) { [] }
  let(:handlers) do
    registry = described_class::Handlers.new
    %w[payout.paid payout.failed dispute.opened dispute.closed].each do |type|
      registry.register(type) { |db, notification| record(db, notification) }
    end
    registry
  end

  # Each handled notification leaves a ledger transaction under its own id, so the
  # tests can count effects in the database, where a rollback would undo them.
  def record(db, notification)
    seen << notification.id
    Clearinghouse::Ledger.post!(db, flow_type: 'payout', flow_id: notification.id, description: notification.type,
                                    effective_at: notification.created_at,
                                    entries: Clearinghouse::Ledger::Flows.payout_paid(amount: usd(100)))
  end

  def poller(hook: nil, name: 'acquirer', with: handlers)
    described_class.new(db: app_db, client: client, clock: clock, handlers: with, name: name, crash_hook: hook)
  end

  def effects
    app_db[:ledger_transactions].group_and_count(:flow_id).to_h { |r| [r[:flow_id], r[:count]] }
  end

  def send_payouts(*amounts)
    amounts.each_with_index do |amount, i|
      client.payout(reference: "po_#{i}", merchant_id: 'acct_1', amount: usd(amount), idempotency_key: "po-#{i}")
    end
  end

  it 'handles every due notification once, in feed order, and keeps the cursor' do
    send_payouts(1_000, 1_013, 2_000)
    ref = acquirer_charge(payment_method: 'pm_card_disputeFraudulent')
    expect(poller.poll).to have_attributes(processed: 0, cursor: '0')

    clock.advance(SettlementHelpers::DAY)
    first = poller.poll
    expect(first).to have_attributes(processed: 3, already_processed: 0, cursor: '3', unavailable: nil)
    expect(app_db[:processed_notifications].order(:cursor).select_map(:type))
      .to eq(%w[payout.paid payout.failed payout.paid])

    clock.advance(7 * SettlementHelpers::DAY)
    expect(poller.poll).to have_attributes(processed: 1, cursor: '4')
    opened = app_db[:processed_notifications].where(type: 'dispute.opened').first
    expect(JSON.parse(opened[:data])).to include('acquirer_reference' => ref, 'amount' => 10_000)
    expect(opened[:occurred_at]).to eq(Time.utc(2026, 3, 9, 9))
    expect(poller.poll).to have_attributes(processed: 0, cursor: '4')
    expect([effects.values.uniq, seen.length]).to eq([[1], 4])
  end

  it 'follows next_cursor across pages' do
    send_payouts(*Array.new(130) { |i| 1_000 + (i * 100) })
    clock.advance(SettlementHelpers::DAY)
    expect(poller.poll).to have_attributes(processed: 130, cursor: '130')
    expect(effects.length).to eq(130)
  end

  it 'reports an unreachable acquirer without moving the cursor' do
    send_payouts(1_000)
    clock.advance(SettlementHelpers::DAY)
    down = Clearinghouse::Acquirer::Client.new(clock: clock, base_url: "http://127.0.0.1:#{SimServer.closed_port}")
    result = described_class.new(db: app_db, client: down, clock: clock, handlers: handlers).poll
    expect(result.unavailable).to include('connect failed')
    expect(result.cursor).to eq('0')
    expect(poller.poll.processed).to eq(1)
  end

  it 'stops at a notification nobody handles, writes nothing for it, and resumes once a handler exists' do
    send_payouts(1_000, 1_013)
    clock.advance(SettlementHelpers::DAY)
    partial = described_class::Handlers.new.register('payout.paid') { |db, n| record(db, n) }
    expect { poller(with: partial).poll }
      .to raise_error(described_class::UnhandledNotificationError, /payout.failed/)
    expect(app_db[:processed_notifications].select_map(:type)).to eq(['payout.paid'])
    expect(poller.cursor).to eq('1')

    expect(poller.poll).to have_attributes(processed: 1, cursor: '2')
  end

  it 'rolls a failing handler back completely, then applies it once on the next poll' do
    send_payouts(1_000)
    clock.advance(SettlementHelpers::DAY)
    failing = described_class::Handlers.new.register('payout.paid') do |db, n|
      record(db, n)
      raise 'handler bug'
    end
    expect { poller(with: failing).poll }.to raise_error('handler bug')
    expect(effects).to be_empty
    expect(app_db[:processed_notifications].count).to eq(0)
    expect(poller.cursor).to eq('0')

    expect(poller.poll.processed).to eq(1)
    expect(effects.values).to eq([1])
  end

  it 'skips notifications it has already applied when the feed repeats them' do
    send_payouts(1_000, 2_000)
    clock.advance(SettlementHelpers::DAY)
    poller.poll
    owner_db[:acquirer_cursors].where(name: 'acquirer').update(cursor: '0') # a rewound cursor

    expect(poller.poll).to have_attributes(processed: 0, already_processed: 2, cursor: '2')
    expect(effects.values).to eq([1, 1])
    expect(seen.length).to eq(2)
  end

  it 'keeps separate cursors per consumer name' do
    send_payouts(1_000)
    clock.advance(SettlementHelpers::DAY)
    poller.poll
    expect(poller(name: 'shadow').cursor).to eq('0')
    expect(poller(name: 'shadow').poll).to have_attributes(processed: 0, already_processed: 1)
  end

  it 'applies each notification once when two pollers race' do
    send_payouts(*Array.new(40) { |i| 1_000 + (i * 100) })
    clock.advance(SettlementHelpers::DAY)
    results = Array.new(2) { Thread.new { poller.poll } }.map(&:value)
    expect(results.sum(&:processed)).to eq(40)
    expect(effects.length).to eq(40)
    expect(effects.values).to all(eq(1))
    expect(Clearinghouse::Ledger::Invariants.check(app_db)).to be_empty
  end

  it 'collects the handlers bin/poller runs with: disputes and payouts' do
    expect(Clearinghouse::Settlement.notification_handlers(clock: clock).types)
      .to eq(%w[dispute.closed dispute.opened payout.failed payout.paid])
  end

  it 'refuses to register two handlers for one type' do
    expect { handlers.register('payout.paid') { nil } }.to raise_error(ArgumentError, /already registered/)
    expect(handlers.types).to eq(%w[dispute.closed dispute.opened payout.failed payout.paid])
  end

  describe 'crash at every recovery point' do
    described_class::RECOVERY_POINTS.each do |point|
      it "recovers from a crash at #{point} with every effect applied exactly once" do
        send_payouts(1_000, 1_013, 2_000)
        clock.advance(SettlementHelpers::DAY)
        expect { poller(hook: crash_once_at(point)).poll }.to raise_error(SettlementHelpers::SimulatedCrash)

        committed = point == 'committed' ? 1 : 0
        expect(effects.length).to eq(committed)
        expect(poller.cursor).to eq(committed.to_s)

        restarted = poller.poll
        expect(restarted.processed).to eq(3 - committed)
        expect(effects.length).to eq(3)
        expect(effects.values).to all(eq(1))
        expect(app_db[:processed_notifications].count).to eq(3)
        expect(Clearinghouse::Ledger::Invariants.check(app_db)).to be_empty
      end
    end

    # Experiment 2 crashes a real bin/poller at `notification.<type>:<point>`, so the
    # hook must know the type: a crash aimed at payout.failed must pass payout.paid by.
    it 'tells the hook which notification type it is at, so a crash can aim at one type' do
      send_payouts(1_000, 1_013, 2_000)
      clock.advance(SettlementHelpers::DAY)
      reached = []
      hook = lambda do |point, type|
        reached << [type, point]
        raise SettlementHelpers::SimulatedCrash if [type, point] == %w[payout.failed effects_written]
      end
      expect { poller(hook: hook).poll }.to raise_error(SettlementHelpers::SimulatedCrash)

      expect(reached).to eq([%w[payout.paid notification_fetched], %w[payout.paid effects_written],
                             %w[payout.paid committed], %w[payout.failed notification_fetched],
                             %w[payout.failed effects_written]])
      expect(effects.length).to eq(1)
      expect(poller.cursor).to eq('1')
    end
  end
end
