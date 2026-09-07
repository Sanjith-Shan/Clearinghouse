# typed: false
# frozen_string_literal: true

require_relative 'db'

DBHelper.clean_tables('merchants', 'scheduled_availabilities')

# Builders for balance and payout specs. `capture!` does what the payments area's
# capture phase will do (post the capture and schedule its availability in one
# transaction), so these specs exercise the same ledger path without depending on
# payment_intents.
module BalanceHelpers
  DAY = Clearinghouse::Clock::SECONDS_PER_DAY

  def new_merchant(clock:, db: app_db, payout_delay_days: 2, payout_interval: 'daily')
    Clearinghouse::Merchants.create(db, clock: clock, name: 'Rocket Rides', api_version: '2026-09-01',
                                        payout_delay_days: payout_delay_days, payout_interval: payout_interval).first
  end

  # Captures `gross` for the merchant at the clock's now and returns [pi id, net].
  def capture!(merchant, gross, clock:, db: app_db, currency: 'usd')
    flow_id = Clearinghouse::Ids.generate('pi')
    net, fee = merchant.fee_schedule.split(Clearinghouse::Money.of(gross, currency))
    db.transaction do
      Clearinghouse::Ledger.post!(db, flow_type: 'payment', flow_id: flow_id, description: 'capture',
                                      effective_at: clock.now,
                                      entries: Clearinghouse::Ledger::Flows.capture(merchant_id: merchant.id,
                                                                                    gross: net + fee, fee: fee))
      available_on = Clearinghouse::Balances::Availability.available_on_for(db, merchant_id: merchant.id,
                                                                                captured_at: clock.now)
      Clearinghouse::Balances::Availability.schedule!(db, flow_id: flow_id, merchant_id: merchant.id, net: net,
                                                          available_on: available_on, clock: clock)
    end
    [flow_id, net]
  end

  def merchant_balance(merchant, name, currency = 'usd', db: app_db)
    Clearinghouse::Ledger.balance(db, Clearinghouse::Ledger::AccountCode.merchant(merchant.id, name), currency).amount
  end

  def platform_balance(name, currency = 'usd', db: app_db)
    Clearinghouse::Ledger.balance(db, "platform:#{name}", currency).amount
  end

  # Starts every thread, then lets them all go at once, so the work inside really
  # overlaps instead of running in thread start order.
  def run_concurrently(count)
    gate = Queue.new
    threads = Array.new(count) do |i|
      Thread.new do
        gate.pop
        yield i
      end
    end
    count.times { gate << :go }
    threads.map(&:value)
  end
end

RSpec.configure do |config|
  config.include BalanceHelpers, :db
end
