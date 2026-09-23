# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Balances::Holds, :db do
  include PayoutHelpers

  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { new_merchant(clock: clock) }
  let(:holds) { described_class }
  let(:refunds) { StandInRefunds.new }
  let(:availability) { Clearinghouse::Balances::Availability }

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  def open_hold(flow_id, amount = 10_000)
    holds.open_hold!(app_db, flow_id: flow_id, merchant_id: merchant.id, amount: money(amount),
                             reason: 'rule:high_velocity', clock: clock, events: events)
  end

  def close(hold, decision)
    holds.close_hold!(app_db, hold.id, merchant_id: merchant.id, decision: decision, clock: clock, events: events,
                                       refunds: refunds)
  end

  def sweep(days: 3)
    clock.advance(days * BalanceHelpers::DAY)
    availability.release_due!(app_db, clock: clock)
  end

  def payout!
    Clearinghouse::Payouts.create!(app_db, merchant_id: merchant.id, currency: 'usd', bank: bank, clock: clock)
  end

  describe 'a payment under review' do
    it 'is released to held, not available, and no payout can include it' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      open_hold(reviewed)
      capture!(merchant, 5_000, clock: clock) # a clean payment, net 4,825

      report = sweep
      expect([report.count('held'), report.count('available')]).to eq([1, 1])
      expect(merchant_balance(merchant, 'held')).to eq(9_680)
      expect(merchant_balance(merchant, 'available')).to eq(4_825)
      expect(holds.find(app_db, flow_id: reviewed).held_amount).to eq(9_680)

      payout = payout!
      expect(payout.amount).to eq(money(4_825)) # the whole available balance, and nothing of the held
      expect(merchant_balance(merchant, 'held')).to eq(9_680)
      expect(sim.simulator.payouts.sum(&:amount)).to eq(4_825)
      expect { payout! }.to raise_error(Clearinghouse::Payouts::BalanceInsufficientError)
    end

    it 'becomes payable once approved' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      hold = open_hold(reviewed)
      sweep

      closed = close(hold, :approve)
      expect(closed).to have_attributes(open?: false, resolution: 'approved', held_amount: 0)
      expect(merchant_balance(merchant, 'held')).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
      expect(payout!.amount).to eq(money(9_680))
      expect(events.types).to eq(%w[review.opened review.closed])
    end

    it 'is simply released to available by the sweep when approved before it was due' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      close(open_hold(reviewed), :approve)
      expect(merchant_balance(merchant, 'held')).to eq(0)

      expect(sweep.count('available')).to eq(1)
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
    end

    it 'moves money that was already available back to held when the review opens late' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      sweep
      hold = open_hold(reviewed)
      expect(hold.held_amount).to eq(9_680)
      expect(merchant_balance(merchant, 'available')).to eq(0)
      expect(merchant_balance(merchant, 'held')).to eq(9_680)
    end
  end

  describe 'rejecting' do
    it 'asks for a refund and releases nothing until the refund takes the money' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      hold = open_hold(reviewed)
      sweep

      closed = close(hold, :reject)
      expect(closed).to have_attributes(resolution: 'rejected', held_amount: 9_680)
      expect(refunds.requested.map { |r| [r[:payment_intent_id], r[:reason]] }).to eq([[reviewed, 'fraudulent']])
      expect(closed.refund_id).to eq(refunds.requested.first[:id])
      expect(holds.withholds?(app_db, reviewed)).to be(true)
      expect(merchant_balance(merchant, 'held')).to eq(9_680)

      refunds.post_refund!(app_db, refund_id: closed.refund_id, payment_intent_id: reviewed,
                                   merchant_id: merchant.id, amount: money(10_000), clock: clock)
      expect(merchant_balance(merchant, 'held')).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq(-320) # our fee is not returned on a refund
      expect(holds.find(app_db, flow_id: reviewed)).to have_attributes(held_amount: 0, refund_applied_at: clock.now)
    end

    it 'keeps the money held if the sweep runs between the reject and the refund' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      closed = close(open_hold(reviewed), :reject)
      expect(sweep.count('held')).to eq(1)

      refunds.post_refund!(app_db, refund_id: closed.refund_id, payment_intent_id: reviewed,
                                   merchant_id: merchant.id, amount: money(10_000), clock: clock)
      expect(merchant_balance(merchant, 'held')).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq(-320)
    end

    it 'lets the sweep release to available once the refund has already posted' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      closed = close(open_hold(reviewed), :reject)
      refunds.post_refund!(app_db, refund_id: closed.refund_id, payment_intent_id: reviewed,
                                   merchant_id: merchant.id, amount: money(10_000), clock: clock)
      expect(merchant_balance(merchant, 'available')).to eq(-10_000)

      expect(sweep.count('available')).to eq(1)
      expect(merchant_balance(merchant, 'available')).to eq(-320)
      expect(merchant_balance(merchant, 'pending')).to eq(0)
    end

    it 'changes nothing when refunds are not wired, rather than closing without a refund' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      hold = open_hold(reviewed)
      expect do
        holds.close_hold!(app_db, hold.id, merchant_id: merchant.id, decision: :reject, clock: clock)
      end.to raise_error(Clearinghouse::Balances::RefundsNotWiredError)
      expect(holds.find(app_db, id: hold.id).open?).to be(true)
    end
  end

  describe 'bookkeeping' do
    it 'opens one hold per payment, however often it is asked' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      first = open_hold(reviewed)
      expect(open_hold(reviewed).id).to eq(first.id)
      expect(events.types).to eq(['review.opened'])
      expect(first.id).to match(/\Aprv_[A-Za-z0-9]{24}\z/)
    end

    it 'refuses to close a hold twice, an unknown one, or another merchant\'s' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      hold = open_hold(reviewed)
      close(hold, :approve)
      expect { close(hold, :reject) }.to raise_error(described_class::AlreadyClosedError)
      expect { holds.close_hold!(app_db, hold.id, merchant_id: 'acct_other', decision: :approve, clock: clock) }
        .to raise_error(described_class::NotFoundError)
      expect { close(hold, :maybe) }.to raise_error(ArgumentError)
    end

    it 'treats release_after_refund! as a no-op without a rejected hold, and applies it once' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      expect(holds.release_after_refund!(app_db, flow_id: reviewed, clock: clock, refund_entries: [])).to be_nil
      hold = open_hold(reviewed)
      expect(holds.release_after_refund!(app_db, flow_id: reviewed, clock: clock, refund_entries: []).open?).to be(true)
      sweep
      close(hold, :reject)
      2.times { holds.release_after_refund!(app_db, flow_id: reviewed, clock: clock, refund_entries: []) }
      expect(app_db[:ledger_transactions].where(flow_id: reviewed, description: 'hold released').count).to eq(1)
    end

    it 'lists newest first, filtered by open' do
      flows = Array.new(3) { capture!(merchant, 1_000, clock: clock).first }
      opened = flows.map do |f|
        clock.advance(1)
        open_hold(f, 1_000)
      end
      close(opened[0], :approve)

      all, more = holds.list(app_db, merchant_id: merchant.id, limit: 2)
      expect([all.map(&:id), more]).to eq([[opened[2].id, opened[1].id], true])
      expect(holds.list(app_db, merchant_id: merchant.id, open: false).first.map(&:id)).to eq([opened[0].id])
      expect(holds.list(app_db, merchant_id: merchant.id, open: true, starting_after: opened[2].id).first.map(&:id))
        .to eq([opened[1].id])
      expect { holds.list(app_db, merchant_id: merchant.id, starting_after: 'prv_missing') }
        .to raise_error(described_class::NotFoundError)
    end
  end

  describe 'approvals racing the sweep (real threads, real Postgres)' do
    it 'makes an approval wait for a sweep that has already decided to hold the money' do
      reviewed, = capture!(merchant, 10_000, clock: clock)
      hold = open_hold(reviewed)
      clock.advance(3 * BalanceHelpers::DAY)
      decided = Queue.new
      go_on = Queue.new
      allow(holds).to receive(:withholds?).and_wrap_original do |original, *args|
        result = original.call(*args)
        decided << result
        go_on.pop # the sweep pauses here, holding the availability row's lock
        result
      end

      sweeper = Thread.new { availability.release_due!(app_db, clock: clock) }
      expect(decided.pop).to be(true)
      approver = Thread.new { close(hold, :approve) }
      expect(approver.join(0.5)).to be_nil # blocked behind the sweep, not racing it
      go_on << :continue
      sweeper.join
      approver.join

      expect(merchant_balance(merchant, 'held')).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
      expect(holds.find(app_db, id: hold.id)).to have_attributes(resolution: 'approved', held_amount: 0)
    end

    # The sweep and an approval both lock the merchant's balance rows. A batch that
    # released one payment to available and the next to held used to take
    # `available` in its first posting and `held` in its second, while an approval
    # (held -> available) takes them in account id order, held first here. Each
    # then waited on the other. This forces that interleaving.
    it 'does not deadlock with an approval when one batch releases to both available and held' do
      approved_first, = capture!(merchant, 1_000, clock: clock)
      still_held, = capture!(merchant, 1_000, clock: clock)
      first_hold = open_hold(approved_first, 1_000)
      waiting_hold = open_hold(still_held, 1_000)
      sweep # both to held, which creates the held account
      close(first_hold, :approve) # creates available after held, so held has the lower id
      capture!(merchant, 1_000, clock: clock) # released to available
      reviewed, = capture!(merchant, 1_000, clock: clock) # then, in the same batch, to held
      open_hold(reviewed, 1_000)
      clock.advance(3 * BalanceHelpers::DAY)

      pause = pause_at(holds, :withholds?) { |_db, flow_id| flow_id == reviewed }
      expect do
        interleave(pause, -> { availability.release_due!(app_db, clock: clock) }, -> { close(waiting_hold, :approve) })
      end.not_to raise_error
      expect(merchant_balance(merchant, 'pending')).to eq(0)
      expect(merchant_balance(merchant, 'held')).to eq(941) # reviewed
      expect(merchant_balance(merchant, 'available')).to eq(3 * 941)
    end

    it 'ends with every approved payment in available exactly once and nothing left held' do
      reviewed = Array.new(16) { capture!(merchant, 1_000, clock: clock).first }
      opened = reviewed.map { |f| open_hold(f, 1_000) }
      clock.advance(3 * BalanceHelpers::DAY)

      run_concurrently(5) do |i|
        if i.zero?
          availability.release_due!(app_db, clock: clock, batch_size: 2)
        else
          opened.each_slice(4).to_a[i - 1].each { |h| close(h, :approve) }
        end
      end
      availability.release_due!(app_db, clock: clock) # whatever the racing sweep skipped

      expect(merchant_balance(merchant, 'held')).to eq(0)
      expect(merchant_balance(merchant, 'pending')).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq(16 * 941)
      expect(app_db[:risk_holds].sum(:held_amount)).to eq(0)
    end
  end

  # The refund of a rejected payment posts twice in one transaction (the refund,
  # then the hold's release) and locks the payment's availability row in between.
  # Both used to be able to deadlock. These force each interleaving.
  describe 'the refund of a rejected payment racing (real threads, real Postgres)' do
    def refund!(flow_id, hold)
      refunds.post_refund!(app_db, refund_id: hold.refund_id, payment_intent_id: flow_id, merchant_id: merchant.id,
                                   amount: money(1_000), clock: clock)
    end

    # The refund took `available` and then wanted `held`; an approval of another
    # payment takes them in id order, and here held has the lower id.
    it 'does not deadlock with an approval of another payment' do
      rejected, = capture!(merchant, 1_000, clock: clock)
      approved, = capture!(merchant, 1_000, clock: clock)
      first, = capture!(merchant, 1_000, clock: clock)
      to_reject = open_hold(rejected, 1_000)
      to_approve = open_hold(approved, 1_000)
      first_hold = open_hold(first, 1_000)
      sweep # all three to held, which creates the held account
      close(first_hold, :approve) # creates available after held
      to_reject = close(to_reject, :reject)

      # Where the old refund had posted and held `available`; the new one has locked nothing yet.
      pause = pause_at(holds, :release_after_refund!, before: true)
      expect { interleave(pause, -> { refund!(rejected, to_reject) }, -> { close(to_approve, :approve) }) }
        .not_to raise_error
      expect(merchant_balance(merchant, 'held')).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq((3 * 941) - 1_000)
    end

    # The refund held `available` and waited for the availability row; a sweep
    # holding that row wanted `available` for another payment of the batch.
    it 'does not deadlock with a sweep that has claimed the rejected payment' do
      rejected, = capture!(merchant, 1_000, clock: clock)
      capture!(merchant, 1_000, clock: clock) # released to available in the same batch
      to_reject = close(open_hold(rejected, 1_000), :reject)
      clock.advance(3 * BalanceHelpers::DAY)

      pause = pause_at(holds, :withholds?) { |_db, flow_id| flow_id == rejected }
      sweep_now = -> { availability.release_due!(app_db, clock: clock) }
      expect { interleave(pause, sweep_now, -> { refund!(rejected, to_reject) }) }.not_to raise_error
      expect(merchant_balance(merchant, 'pending')).to eq(0)
      expect(merchant_balance(merchant, 'held')).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq((2 * 941) - 1_000)
      expect(holds.find(app_db, flow_id: rejected)).to have_attributes(held_amount: 0, refund_applied_at: clock.now)
    end
  end
end
