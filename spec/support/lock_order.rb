# typed: false
# frozen_string_literal: true

# Forces two transactions into one interleaving, for the specs that prove a pair
# of code paths cannot deadlock (docs/bugs/payouts-sweep-lock-order-deadlock.md).
# The first runs until it reaches a chosen call and stops there, holding whatever
# locks it has; the second runs until it finishes or waits on a lock; then the
# first goes on. If the two took shared locks in opposite orders, Postgres now
# sees the cycle and aborts one of them, and its error comes out of `interleave`.
module LockOrderHelpers
  PAUSE_TIMEOUT = 10

  # Stops the first call of `receiver.method` for which the block (given the
  # call's arguments) is true, or the first call at all without a block. `before`
  # stops it before the method runs, otherwise just after. Pass the result to
  # `interleave`.
  def pause_at(receiver, method, before: false, &pause_if)
    reached = Queue.new
    gate = Queue.new
    paused = false
    stop = lambda do |args, kwargs|
      next if paused || (pause_if && !pause_if.call(*args, **kwargs))

      paused = true
      reached << true
      gate.pop
    end
    allow(receiver).to receive(method).and_wrap_original do |original, *args, **kwargs|
      stop.call(args, kwargs) if before
      result = original.call(*args, **kwargs)
      stop.call(args, kwargs) unless before
      result
    end
    [reached, gate]
  end

  # Runs `first` to the pause, then `second` until it is done or blocked, then
  # lets `first` finish. Returns both results; raises what either raised.
  def interleave(pause, first, second)
    reached, gate = pause
    one = quiet_thread(&first)
    unless reached.pop(timeout: PAUSE_TIMEOUT)
      raise "the first transaction never reached its pause: #{one.value.inspect}"
    end

    two = quiet_thread(&second)
    wait_until_blocked_or_done(two)
    gate << :go
    [one.value, two.value]
  end

  # Waits until `thread` has finished or some session of this test database is
  # waiting on a lock.
  def wait_until_blocked_or_done(thread, timeout: PAUSE_TIMEOUT)
    waiting = app_db[:pg_stat_activity].where(wait_event_type: 'Lock', datname: Sequel.function(:current_database))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until !thread.alive? || waiting.any?
      raise "#{thread.inspect} neither finished nor blocked in #{timeout}s" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  # From another session: whether some transaction holds this balance row locked.
  def balance_locked?(code, currency = 'usd')
    id = app_db[:ledger_accounts].where(code: code, currency: currency).get(:id)
    quiet_thread { app_db.transaction { app_db[:account_balances].where(account_id: id).for_update.nowait.all } }.join
    false
  rescue Sequel::DatabaseError => e
    raise unless e.message.include?('could not obtain lock')

    true
  end

  private

  # The error is the test's result, not noise for the log.
  def quiet_thread(&)
    thread = Thread.new(&)
    thread.report_on_exception = false
    thread
  end
end

RSpec.configure do |config|
  config.include LockOrderHelpers, :db
end
