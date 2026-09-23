# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Payouts, :db do
  include PayoutHelpers

  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { new_merchant(clock: clock, payout_delay_days: 0) }
  let(:payouts) { described_class }

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  def create(amount: nil, currency: 'usd')
    payouts.create!(app_db, merchant_id: merchant.id, currency: currency, bank: bank, clock: clock, amount: amount,
                            events: events)
  end

  def reserve(amount: nil)
    payouts.reserve!(app_db, merchant_id: merchant.id, currency: 'usd', clock: clock, amount: amount, events: events)
  end

  describe 'creating a payout' do
    it 'moves the whole available balance to payout_clearing by default and sends it to the bank' do
      fund!(merchant, 10_000)
      payout = create

      expect(payout).to have_attributes(amount: money(9_680), status: 'in_transit', recovery_point: 'bank_recorded',
                                        automatic: false, bank_idempotency_key: "#{payout.id}:bank")
      expect(payout.acquirer_reference).to start_with('acqpo_')
      expect(merchant_balance(merchant, 'available')).to eq(0)
      expect(platform_balance('payout_clearing')).to eq(9_680)
      expect(sim_payouts(payout.id).map(&:amount)).to eq([9_680])
      expect(events.types).to eq(['payout.created'])
    end

    it 'pays out part of the balance when asked for an amount' do
      fund!(merchant, 10_000)
      expect(create(amount: 5_000).amount).to eq(money(5_000))
      expect(merchant_balance(merchant, 'available')).to eq(4_680)
    end

    it 'refuses an amount larger than the available balance and writes nothing' do
      fund!(merchant, 10_000)
      expect { create(amount: 9_681) }.to raise_error(described_class::BalanceInsufficientError, /cannot cover/)
      expect(app_db[:payouts].count).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
    end

    it 'refuses while nothing is available, including money that is still pending' do
      capture!(new_merchant(clock: clock), 10_000, clock: clock) # someone else's pending money
      capture!(merchant, 10_000, clock: clock) # due, but the sweep has not run
      expect { create }.to raise_error(described_class::BalanceInsufficientError, /nothing to pay out/)
      expect(sim.simulator.payouts).to be_empty
    end

    it 'returns the existing automatic payout for a day instead of making a second one' do
      fund!(merchant, 10_000)
      day = Date.new(2026, 9, 1)
      first = payouts.reserve!(app_db, merchant_id: merchant.id, currency: 'usd', clock: clock, scheduled_for: day)
      fund!(merchant, 10_000)
      again = payouts.reserve!(app_db, merchant_id: merchant.id, currency: 'usd', clock: clock, scheduled_for: day)
      expect(again.id).to eq(first.id)
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
    end

    it 'refuses a non-positive amount before touching the database' do
      expect { reserve(amount: 0) }.to raise_error(ArgumentError)
    end
  end

  describe 'the bank answers later' do
    it 'settles payout_clearing to cash on payout.paid, a simulated day later' do
      fund!(merchant, 10_000)
      payout = create
      expect(deliver_notifications!).to eq([])

      clock.advance(BalanceHelpers::DAY)
      expect(deliver_notifications!).to eq([:applied])
      expect(payouts.find(app_db, payout.id)).to have_attributes(status: 'paid')
      expect(platform_balance('payout_clearing')).to eq(0)
      expect(platform_balance('cash')).to eq(-9_680) # no settlement posted in this test, only the payout
      expect(explained?(payout.id)).to be(true)
      expect(events.types).to eq(%w[payout.created payout.paid])
    end

    it 'returns the money to available on payout.failed' do
      fund!(merchant, 10_000)
      payout = create(amount: 1_013) # the simulator fails amounts ending in 13
      clock.advance(BalanceHelpers::DAY)
      deliver_notifications!

      expect(payouts.find(app_db, payout.id)).to have_attributes(status: 'failed', failure_code: 'account_closed')
      expect(payouts.find(app_db, payout.id).to_api['failure_message']).to eq('The bank account has been closed.')
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
      expect(platform_balance('payout_clearing')).to eq(0)
      expect(explained?(payout.id)).to be(true)
      expect(events.types).to eq(%w[payout.created payout.failed])
    end

    it 'applies a notification once, however often it is delivered' do
      fund!(merchant, 10_000)
      payout = create
      clock.advance(BalanceHelpers::DAY)
      notification = bank.notifications(after: '0').data.fetch(0)

      results = Array.new(3) { payouts.handle_notification(app_db, notification, clock: clock, events: events) }
      expect(results).to eq(%i[applied duplicate duplicate])
      expect(app_db[:ledger_transactions].where(flow_id: payout.id).count).to eq(2)
      expect(events.types.count('payout.paid')).to eq(1)
    end

    it 'ignores other notification types and reports payouts it does not know' do
      other = Clearinghouse::Acquirer::Notification.new(id: 'ntf_1', type: 'dispute.opened', created_at: clock.now,
                                                        cursor: '1', data: {})
      unknown = Clearinghouse::Acquirer::Notification.new(id: 'ntf_2', type: 'payout.paid', created_at: clock.now,
                                                          cursor: '2', data: { 'reference' => 'po_missing' })
      expect(payouts.handle_notification(app_db, other, clock: clock)).to eq(:ignored)
      expect(payouts.handle_notification(app_db, unknown, clock: clock)).to eq(:unknown_payout)
    end

    it 'refuses a notification that contradicts what was recorded' do
      fund!(merchant, 10_000)
      payout = create
      clock.advance(BalanceHelpers::DAY)
      paid = bank.notifications(after: '0').data.fetch(0)
      fields = { id: paid.id, created_at: paid.created_at, cursor: paid.cursor }
      failed = Clearinghouse::Acquirer::Notification.new(**fields, type: 'payout.failed', data: paid.data)
      wrong_ref = Clearinghouse::Acquirer::Notification.new(
        **fields, type: 'payout.paid', data: paid.data.merge('acquirer_reference' => 'acqpo_other')
      )

      expect { payouts.handle_notification(app_db, wrong_ref, clock: clock) }
        .to raise_error(described_class::NotificationConflictError, /acqpo_other/)
      payouts.handle_notification(app_db, paid, clock: clock)
      expect { payouts.handle_notification(app_db, failed, clock: clock) }
        .to raise_error(described_class::NotificationConflictError, /which is paid/)
      expect(payouts.find(app_db, payout.id).status).to eq('paid')
    end
  end

  describe 'cancel' do
    it 'reverses the reservation of a payout that has not gone to the bank' do
      fund!(merchant, 10_000)
      payout = reserve
      canceled = payouts.cancel!(app_db, payout.id, merchant_id: merchant.id, clock: clock, events: events)

      expect(canceled.status).to eq('canceled')
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
      expect(explained?(payout.id)).to be(true)
      expect(events.types).to eq(%w[payout.created payout.canceled])
      expect(payouts.drive!(app_db, payout.id, bank: bank, clock: clock).status).to eq('canceled')
      expect(sim.simulator.payouts).to be_empty
    end

    it 'refuses once the payout has been sent, or twice' do
      fund!(merchant, 10_000)
      sent = create(amount: 1_000)
      canceled = reserve(amount: 1_000)
      payouts.cancel!(app_db, canceled.id, merchant_id: merchant.id, clock: clock)

      expect { payouts.cancel!(app_db, sent.id, merchant_id: merchant.id, clock: clock) }
        .to raise_error(described_class::NotCancelableError, /in_transit/)
      expect { payouts.cancel!(app_db, canceled.id, merchant_id: merchant.id, clock: clock) }
        .to raise_error(described_class::NotCancelableError, /canceled/)
      expect { payouts.cancel!(app_db, sent.id, merchant_id: 'acct_other', clock: clock) }
        .to raise_error(described_class::NotFoundError)
    end

    it 'refuses once the bank has been asked, even while the payout is still pending' do
      fund!(merchant, 10_000)
      asked = payouts.request_bank!(app_db, reserve.id, clock: clock)
      expect(asked.status).to eq('pending')
      expect { payouts.cancel!(app_db, asked.id, merchant_id: merchant.id, clock: clock) }
        .to raise_error(described_class::NotCancelableError, /already been sent to the bank/)
    end
  end

  describe 'resuming after a crash or a lost answer (the recovery points)' do
    before { fund!(merchant, 10_000) }

    def resume
      clock.advance(described_class::STALE_AFTER_SECONDS)
      payouts.resume_incomplete!(app_db, bank: bank, clock: clock, events: events)
    end

    it 'lists the points in order, with the row-level ones in the middle' do
      expect(described_class::RECOVERY_POINTS).to eq(%w[started balance_reserved bank_requested bank_recorded finished])
      expect(described_class::RECOVERY_POINTS[1..3]).to eq(described_class::ROW_RECOVERY_POINTS)
    end

    it 'crash at balance_reserved: the resume sends it' do
      payout = reserve
      expect(resume.map(&:id)).to eq([payout.id])
      expect(payouts.find(app_db, payout.id).status).to eq('in_transit')
      expect(sim_payouts(payout.id).length).to eq(1)
    end

    it 'crash at bank_requested before the call: the resume asks the bank, hears nothing, and sends once' do
      payout = payouts.request_bank!(app_db, reserve.id, clock: clock)
      expect(payout.recovery_point).to eq('bank_requested')
      resume
      expect(payouts.find(app_db, payout.id)).to have_attributes(status: 'in_transit', recovery_point: 'bank_recorded')
      expect(sim_payouts(payout.id).length).to eq(1)
    end

    it 'crash after the bank accepted but before recording: the resume finds it and does not send again' do
      payout = payouts.request_bank!(app_db, reserve.id, clock: clock)
      payouts.call_bank(bank, payout, resuming: false) # the answer is lost with the process
      allow(bank).to receive(:payout).and_call_original
      resume
      expect(bank).not_to have_received(:payout)
      expect(payouts.find(app_db, payout.id).status).to eq('in_transit')
      expect(sim_payouts(payout.id).length).to eq(1)
    end

    it 'lost response (Unknown): stays at bank_requested, then the resume records what the bank did' do
      sim.simulator.configure('drop_after_commit_rate' => 1.0)
      payout = create
      expect(payout).to have_attributes(status: 'pending', recovery_point: 'bank_requested')
      expect(sim_payouts(payout.id).length).to eq(1) # the bank did commit it

      sim.simulator.configure('drop_after_commit_rate' => 0.0)
      resume
      expect(payouts.find(app_db, payout.id).status).to eq('in_transit')
      expect(sim_payouts(payout.id).length).to eq(1)
      clock.advance(BalanceHelpers::DAY)
      deliver_notifications!
      expect(explained?(payout.id)).to be(true)
    end

    it 'bank unavailable: nothing sent, the resume sends it once the bank is back' do
      sim.simulator.configure('error_rate' => 1.0)
      payout = create
      expect(payout).to have_attributes(status: 'pending', recovery_point: 'bank_requested')
      expect(sim.simulator.payouts).to be_empty
      expect(resume.map(&:status)).to eq(['pending']) # still down: lookups are refused too

      sim.simulator.configure('error_rate' => 0.0)
      expect(resume.map(&:status)).to eq(['in_transit'])
      expect(sim_payouts(payout.id).length).to eq(1)
    end

    it 'records a payout.paid that arrives while the request is still stuck at bank_requested' do
      sim.simulator.configure('drop_after_commit_rate' => 1.0)
      payout = create
      clock.advance(BalanceHelpers::DAY)
      expect(deliver_notifications!).to eq([:applied])
      expect(payouts.find(app_db, payout.id)).to have_attributes(status: 'paid', recovery_point: 'bank_recorded')
      expect(resume).to be_empty # finished, nothing left to drive
      expect(explained?(payout.id)).to be(true)
    end

    it 'leaves fresh payouts alone so it does not race a live request' do
      reserve
      expect(payouts.resume_incomplete!(app_db, bank: bank, clock: clock)).to be_empty
    end
  end

  describe 'a bank that declines' do
    it 'fails the payout and returns the money in the same transaction' do
      fund!(merchant, 10_000)
      payout = payouts.request_bank!(app_db, reserve.id, clock: clock)
      operation = Clearinghouse::Acquirer::Operation.new(
        id: 'op_1', type: 'payout', status: 'failed', decline_code: 'could_not_process', acquirer_reference: nil,
        reference: payout.id, amount: 9_680, currency: 'usd', idempotency_key: payout.bank_idempotency_key,
        created_at: clock.now
      )
      declined = Clearinghouse::Acquirer::Declined.new(code: 'could_not_process', operation: operation)
      recorded = payouts.record_bank!(app_db, payout.id, declined, clock: clock, events: events)

      expect(recorded).to have_attributes(status: 'failed', failure_code: 'could_not_process')
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
      expect(explained?(payout.id)).to be(true)
      expect(events.types).to eq(%w[payout.created payout.failed])
      expect(payouts.record_bank!(app_db, payout.id, declined, clock: clock).status).to eq('failed')
    end
  end

  describe 'a payout racing a cancel of an earlier one (real threads, real Postgres)' do
    # reserve! locked available, then took payout_clearing when it posted. A cancel
    # (or a failure) posts to the same two accounts, locked in account id order, and
    # here payout_clearing has the lower id: it was created by another merchant's
    # payout before this merchant had an available balance.
    it 'does not deadlock' do
      other = new_merchant(clock: clock, payout_delay_days: 0)
      fund!(other, 10_000)
      payouts.reserve!(app_db, merchant_id: other.id, currency: 'usd', clock: clock, events: events)
      fund!(merchant, 10_000)
      first = reserve(amount: 1_000)

      pause = pause_at(Clearinghouse::Ledger, :balance_for_update)
      cancel = -> { payouts.cancel!(app_db, first.id, merchant_id: merchant.id, clock: clock, events: events) }
      _, canceled = interleave(pause, -> { reserve(amount: 2_000) }, cancel)
      expect(canceled.status).to eq('canceled')
      expect(merchant_balance(merchant, 'available')).to eq(9_680 - 2_000)
      expect(platform_balance('payout_clearing')).to eq(9_680 + 2_000)
    end
  end

  describe 'concurrent payouts against one balance (real threads, real Postgres)' do
    it 'never overdraws: exactly as many succeed as the balance covers' do
      fund!(merchant, 10_000) # 9,680 available
      results = run_concurrently(12) do
        create(amount: 1_000)
      rescue described_class::BalanceInsufficientError => e
        e
      end

      created = results.grep(described_class::Payout)
      expect(created.length).to eq(9)
      expect(results.grep(described_class::BalanceInsufficientError).length).to eq(3)
      expect(merchant_balance(merchant, 'available')).to eq(680)
      expect(platform_balance('payout_clearing')).to eq(9_000)
      expect(sim.simulator.payouts.sum(&:amount)).to eq(9_000)
    end
  end
end
