# typed: false
# frozen_string_literal: true

require_relative '../../sim/experiments/isolation'

# Experiment 3 in miniature. Two connections, each running one operation, with
# the interleaving forced rather than raced: T1 reads, T2 reads (or is blocked
# trying to), T1 writes and commits, T2 carries on. That is the history that
# breaks read-then-write, and the spec shows the other two strategies survive it.
RSpec.describe 'Experiment 3 isolation strategies' do
  let(:admin) { Clearinghouse::DB.connect(role: :owner, max_connections: 1) }
  let(:actors) { Array.new(2) { Clearinghouse::DB.connect(role: :owner, max_connections: 1) } }
  let(:refund) { ->(tx) { Experiments::Isolation::Operations.refund(tx, 1, 1_000) } }
  let(:payout) { ->(tx) { Experiments::Isolation::Operations.payout(tx) } }
  let(:dispute) { ->(tx) { Experiments::Isolation::Operations.dispute(tx, 1_500) } }

  after do
    actors.each(&:disconnect)
    admin.disconnect
  end

  # Runs op1 on actors[0] and op2 on actors[1] in the order above. Returns both
  # [result, attempts] pairs and the audit.
  def interleave(strategy, op1, op2)
    pids = actors.map { |db| db.get(Sequel.function(:pg_backend_pid)) }
    reached = Queue.new
    gates = [Queue.new, Queue.new]
    start = lambda do |i, op|
      Thread.new do
        strategy.run(actors[i], pause: lambda {
          reached << i
          gates[i].pop
        }, &op)
      end
    end

    first = start.call(0, op1)
    expect(reached.pop).to eq(0)
    second = start.call(1, op2)
    wait_until { !reached.empty? || lock_waiting?(pids[1]) }
    gates[0] << :go
    results = [first.value]
    # T2 may pause again: after the lock is released, or on a SERIALIZABLE retry.
    3.times { gates[1] << :go }
    results << second.value
    [results, Experiments::Isolation::Audit.run(admin)]
  end

  def lock_waiting?(pid)
    admin[:pg_stat_activity].where(pid: pid).get(:wait_event_type) == 'Lock'
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'interleaving did not happen' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  # One payment of 1_000 captured, so exactly one 1_000 refund fits.
  before { Experiments::Isolation::Schema.reset!(admin, payments: 1, captured: 1_000, available: 5_000) }

  describe 'two refunds of the whole payment' do
    it 'over-refunds under READ COMMITTED read-then-write' do
      results, audit = interleave(Experiments::Isolation::Strategies::ReadThenWrite.new, refund, refund)

      expect(results).to eq([[:applied, 1], [:applied, 1]])
      expect(audit).to include('over_refunds' => 1, 'over_refunded_cents' => 1_000)
      # Both refunds wrote amount_refunded = 1_000 and available = 4_000.
      expect(audit.fetch('lost_updates')).to eq(2)
      expect(audit.fetch('balance_drift_cents')).to eq(1_000)
    end

    it 'cannot over-refund with SELECT ... FOR UPDATE: the second waits, then sees the first' do
      results, audit = interleave(Experiments::Isolation::Strategies::ForUpdate.new, refund, refund)

      expect(results).to eq([[:applied, 1], [:declined, 1]])
      expect(audit.values).to all(eq(0))
    end

    it 'cannot over-refund under SERIALIZABLE: the second aborts, retries, and sees the first' do
      results, audit = interleave(Experiments::Isolation::Strategies::SerializableRetry.new, refund, refund)

      expect(results).to eq([[:applied, 1], [:declined, 2]])
      expect(audit.values).to all(eq(0))
    end
  end

  describe 'a payout racing a dispute' do
    it 'pays out money the dispute took under read-then-write' do
      results, audit = interleave(Experiments::Isolation::Strategies::ReadThenWrite.new, payout, dispute)

      expect(results).to eq([[:applied, 1], [:applied, 1]])
      # The payout paid 5_000; the dispute then wrote 5_000 - 1_500 over the zero.
      expect(audit).to include('payout_double_spends' => 1, 'lost_updates' => 1, 'balance_drift_cents' => 5_000)
      expect(admin[:iso_balances].get(:available)).to eq(3_500)
    end

    it 'carries the dispute negative after the payout with FOR UPDATE' do
      results, audit = interleave(Experiments::Isolation::Strategies::ForUpdate.new, payout, dispute)

      expect(results).to eq([[:applied, 1], [:applied, 1]])
      expect(audit.values).to all(eq(0))
      expect(admin[:iso_balances].get(:available)).to eq(-1_500)
    end

    it 'carries the dispute negative after the payout under SERIALIZABLE, after one retry' do
      results, audit = interleave(Experiments::Isolation::Strategies::SerializableRetry.new, payout, dispute)

      expect(results).to eq([[:applied, 1], [:applied, 2]])
      expect(audit.values).to all(eq(0))
      expect(admin[:iso_balances].get(:available)).to eq(-1_500)
    end
  end

  describe 'Runner' do
    it 'runs a small mixed workload on each strategy and the safe ones stay clean' do
      db = Clearinghouse::DB.connect(role: :owner, max_connections: 4)
      results = Experiments::Isolation::Strategies::ALL.to_h do |strategy|
        plan = Experiments::Isolation::Plan.new(threads: 4, ops: 120, seed: 1)
        [strategy.name, Experiments::Isolation::Runner.new(db: db, strategy: strategy, plan: plan).run]
      end
      db.disconnect

      results.each_value { |r| expect(r.fetch('completed') + r.fetch('exhausted')).to eq(120) }
      expect(results.fetch('rc_for_update').fetch('anomalies').values).to all(eq(0))
      expect(results.fetch('serializable_retry').fetch('anomalies').values).to all(eq(0))
      row = Experiments::Isolation.aggregate([results.fetch('rc_for_update')])
      expect(Experiments::Isolation.table([row])).to include('| rc_for_update | 4 | 1 |')
    end
  end
end
