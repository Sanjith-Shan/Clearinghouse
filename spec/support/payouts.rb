# typed: false
# frozen_string_literal: true

require_relative 'db'
require_relative 'balances'
require_relative '../sim/sim_helper'

DBHelper.clean_tables('payouts')

# Stand-in for the events outbox (payments area) until Events.emit! lands. It
# records what would have been emitted and checks the one property the outbox
# depends on: every event is emitted inside the transaction of its state change.
class RecordingEventSink
  include Clearinghouse::Balances::EventSink

  attr_reader :events

  def initialize
    @events = []
    @mutex = Mutex.new
  end

  def emit!(db, merchant_id:, type:, object:, clock:)
    raise 'event emitted outside the state change transaction' unless db.in_transaction?
    raise "unknown event type #{type}" unless Clearinghouse::Balances::EVENT_TYPES.include?(type)

    @mutex.synchronize { @events << { merchant_id: merchant_id, type: type, object: object, at: clock.now } }
  end

  def types
    @events.map { |e| e[:type] }
  end
end

# A real simulator on a real socket (the bank for payouts), and the real client.
module PayoutHelpers
  def self.included(base)
    base.let(:sim) { SimServer.start }
    base.let(:bank) { Clearinghouse::Acquirer::Client.new(clock: clock, base_url: sim.url) }
    base.let(:events) { RecordingEventSink.new }
    base.after { sim.stop }
  end

  # Captures `gross` and releases it to available at once. The merchant must have
  # payout_delay_days 0. Returns the net.
  def fund!(merchant, gross, currency: 'usd')
    _, net = capture!(merchant, gross, clock: clock, currency: currency)
    Clearinghouse::Balances::Availability.release_due!(app_db, clock: clock)
    net.amount
  end

  # Polls every notification due by the clock and hands the payout ones to the
  # handler, the way the notification poller will.
  def deliver_notifications!
    page = bank.notifications(after: @notification_cursor || '0')
    @notification_cursor = page.next_cursor
    page.data.map { |n| Clearinghouse::Payouts.handle_notification(app_db, n, clock: clock, events: events) }
  end

  def sim_payouts(reference)
    sim.simulator.payouts.select { |p| p.reference == reference }
  end

  def explained?(flow_id)
    Clearinghouse::Ledger.explain(app_db, flow_id).explained?
  end
end
