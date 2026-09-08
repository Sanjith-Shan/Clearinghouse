# typed: false
# frozen_string_literal: true

require_relative 'db'
require_relative '../sim/sim_helper'

DBHelper.clean_tables('acquirer_cursors', 'processed_notifications', 'disputes', 'merchants')

# Wiring shared by the settlement specs: an in-process simulator on a real port, a
# test clock, and a client that sends the clock as Sim-Time.
module SettlementHelpers
  DAY = Clearinghouse::Clock::SECONDS_PER_DAY

  # Raised by a crash hook to stand in for the process dying at a recovery point.
  class SimulatedCrash < StandardError; end

  def self.included(base)
    base.let(:sim) { SimServer.start }
    base.let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 3, 2, 9)) }
    base.let(:client) { Clearinghouse::Acquirer::Client.new(clock: clock, base_url: sim.url) }
    base.after { sim.stop }
  end

  def usd(amount)
    Clearinghouse::Money.of(amount, 'usd')
  end

  # A captured charge at the acquirer. Returns its acquirer reference.
  def acquirer_charge(amount: 10_000, currency: 'usd', payment_method: 'pm_card_visa', key: SecureRandom.hex(8))
    outcome = client.authorize(payment_method: payment_method, amount: Clearinghouse::Money.of(amount, currency),
                               capture: true, reference: "pi_#{key}", idempotency_key: key)
    raise "authorize failed: #{outcome.inspect}" unless outcome.is_a?(Clearinghouse::Acquirer::Approved)

    outcome.operation.acquirer_reference
  end

  # A hook that crashes once, the first time `point` is reached.
  def crash_once_at(point)
    fired = false
    lambda do |reached|
      next if fired || reached != point

      fired = true
      raise SimulatedCrash, "crashed at #{point}"
    end
  end
end

# Stand-in for the payments work's lookup over payment_intents.acquirer_reference,
# which is not on main yet. Replace with the real one when it lands.
class StandInPaymentLookup
  include Clearinghouse::PaymentLookup

  def initialize
    @payments = {}
  end

  def add_payment(acquirer_reference, id:, merchant_id:, currency: 'usd')
    @payments[acquirer_reference] = Clearinghouse::PaymentLookup::Payment.new(id: id, merchant_id: merchant_id,
                                                                              currency: currency)
  end

  def by_acquirer_reference(_db, acquirer_reference)
    @payments[acquirer_reference]
  end
end

# Stand-in for Events.emit! (the payments work's outbox). It records an event only
# when the database transaction it was emitted in commits, which is the property the
# real outbox gets from being a row in that transaction.
class RecordingEvents
  include Clearinghouse::Disputes::EventSink

  Event = Struct.new(:id, :merchant_id, :type, :object, :created, keyword_init: true)

  attr_reader :committed

  def initialize
    @committed = []
    @mutex = Mutex.new
  end

  def emit!(db, merchant_id:, type:, object:, clock:)
    event = Event.new(id: Clearinghouse::Ids.generate('evt'), merchant_id: merchant_id, type: type,
                      object: JSON.parse(JSON.generate(object)), created: clock.now.to_i)
    db.after_commit { @mutex.synchronize { @committed << event } }
    event.id
  end

  def types
    committed.map(&:type)
  end
end

# A merchant, a payment captured at the acquirer and in our ledger with its funds
# available, and the lookup entry that ties the two together.
module DisputeHelpers
  def self.included(base)
    base.let(:lookup) { StandInPaymentLookup.new }
    base.let(:events) { RecordingEvents.new }
    base.let(:service) { Clearinghouse::Disputes::Service.new(lookup: lookup, events: events, clock: clock) }
    base.let(:merchant) do
      Clearinghouse::Merchants.create(app_db, clock: clock, name: 'Rocket Rides', api_version: '2026-09-01').first
    end
  end

  def available(currency = 'usd')
    balance_of("merchant:#{merchant.id}:available", currency)
  end

  # Returns [payment_intent id, acquirer reference].
  def captured_payment(amount: 10_000, currency: 'usd', payment_method: 'pm_card_disputeFraudulent')
    key = SecureRandom.hex(8)
    reference = acquirer_charge(amount: amount, currency: currency, payment_method: payment_method, key: key)
    pi = "pi_#{key}"
    lookup.add_payment(reference, id: pi, merchant_id: merchant.id, currency: currency)
    gross = Clearinghouse::Money.of(amount, currency)
    net, fee = merchant.fee_schedule.split(gross)
    flows = Clearinghouse::Ledger::Flows
    [flows.capture(merchant_id: merchant.id, gross: gross, fee: fee),
     flows.funds_available(merchant_id: merchant.id, net: net)].each do |entries|
      Clearinghouse::Ledger.post!(app_db, flow_type: 'payment', flow_id: pi, description: "payment #{pi}",
                                          effective_at: clock.now, entries: entries)
    end
    [pi, reference]
  end

  def poller(hook: nil, handlers: service.register(Clearinghouse::Acquirer::NotificationPoller::Handlers.new))
    Clearinghouse::Acquirer::NotificationPoller.new(db: app_db, client: client, clock: clock, handlers: handlers,
                                                    crash_hook: hook)
  end

  def resolve_at_acquirer(outcome)
    dispute = sim.simulator.disputes.first
    sim.simulator.resolve_dispute(dispute.id, outcome, clock.now)
  end

  def the_dispute
    rows = app_db[:disputes].all
    raise "expected one dispute, found #{rows.length}" unless rows.length == 1

    Clearinghouse::Disputes::Dispute.from_row(rows.first)
  end
end
