# typed: strict
# frozen_string_literal: true

module Clearinghouse
  # Automatic payouts on the merchant's schedule. See payouts.rb.
  module Payouts
    extend T::Sig

    # Weekly payouts go out on Mondays, Stripe's default weekly anchor. There is no
    # per-merchant anchor yet; adding one is a column and this constant becoming
    # its default.
    WEEKLY_ANCHOR_WDAY = 1

    # Automatic payouts, driven by the clock. For each merchant whose schedule says
    # today (daily, or weekly on a Monday) and each currency with a positive
    # available balance, it pays out the whole available balance, one payout per
    # merchant, currency and UTC day however often it runs. Manual merchants are
    # skipped. Returns the payouts this run made.
    #
    # Run it after Availability.release_due!, so today's newly available money is
    # included.
    sig do
      params(db: Sequel::Database, bank: Acquirer::Client, clock: Clock,
             events: Balances::EventSink).returns(T::Array[Payout])
    end
    def self.run_scheduled!(db, bank:, clock:, events: Balances::DEFAULT_EVENTS)
      today = clock.now.utc.to_date
      intervals = ['daily']
      intervals << 'weekly' if today.wday == WEEKLY_ANCHOR_WDAY

      due_balances(db, intervals, today).filter_map do |merchant_id, currency|
        payout = reserve!(db, merchant_id: merchant_id, currency: currency, clock: clock, scheduled_for: today,
                              events: events)
        drive!(db, payout.id, bank: bank, clock: clock, events: events)
      rescue BalanceInsufficientError
        # Spent (or taken by a dispute) between the scan and the lock. Nothing to pay.
        nil
      end
    end

    # [merchant_id, currency] for every positive available balance of a merchant
    # on one of these schedules that has no automatic payout for today yet. Read
    # without locks: reserve! re-checks both under the balance row's lock.
    sig do
      params(db: Sequel::Database, intervals: T::Array[String], today: Date).returns(T::Array[[String, String]])
    end
    def self.due_balances(db, intervals, today)
      db.fetch(<<~SQL, intervals, today).map { |row| [row.fetch(:merchant_id), row.fetch(:currency)] }
        SELECT m.id AS merchant_id, a.currency
          FROM merchants m
          JOIN ledger_accounts a ON a.code = 'merchant:' || m.id || ':available'
          JOIN account_balances b ON b.account_id = a.id
         WHERE m.payout_interval IN ? AND b.balance > 0
           AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.automatic AND p.merchant_id = m.id
                                                     AND p.currency = a.currency AND p.scheduled_for = ?)
         ORDER BY m.id, a.currency
      SQL
    end
    private_class_method :due_balances
  end
end
