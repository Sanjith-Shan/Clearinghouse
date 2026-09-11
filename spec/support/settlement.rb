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

# A merchant, and payments made through the real payments code against the
# simulator (the same operations the API runs, with a background context).
module DisputeHelpers
  def self.included(base)
    base.let(:service) { Clearinghouse::Disputes::Service.new(clock: clock) }
    base.let(:merchant) do
      Clearinghouse::Merchants.create(app_db, clock: clock, name: 'Rocket Rides', api_version: '2026-09-01').first
    end
  end

  def available(currency = 'usd')
    balance_of("merchant:#{merchant.id}:available", currency)
  end

  def payments_context(at_clock = clock)
    acquirer = at_clock.equal?(clock) ? client : Clearinghouse::Acquirer::Client.new(clock: at_clock, base_url: sim.url)
    deps = Clearinghouse::Api::Dependencies.new(db: app_db, clock: at_clock, acquirer: acquirer)
    Clearinghouse::Api::Context.background(deps, merchant)
  end

  # Creates and confirms an automatic-capture PaymentIntent, then makes its net
  # available, the posting the payouts work's availability job will make after the
  # settlement delay. Returns [payment_intent id, acquirer reference]. `at_clock`
  # makes the payment with another clock (a lagging one, say).
  def captured_payment(amount: 10_000, currency: 'usd', payment_method: 'pm_card_disputeFraudulent', at_clock: clock)
    payments = Clearinghouse::Payments
    ctx = payments_context(at_clock)
    intent = payments::Operations.create(ctx, payments::Create::Input.new(
                                                amount: amount, currency: currency, payment_method: payment_method,
                                                capture_method: 'automatic', customer_email: nil, metadata: {},
                                                risk_fields: {}
                                              ))
    done = payments::Operations.confirm(ctx, payments::Confirm::Input.new(intent_id: intent.id, payment_method: nil))
    net = merchant.fee_schedule.split(Clearinghouse::Money.of(amount, currency)).first
    Clearinghouse::Ledger.post!(app_db, flow_type: 'payment', flow_id: done.id, description: 'funds available',
                                        effective_at: at_clock.now,
                                        entries: Clearinghouse::Ledger::Flows.funds_available(merchant_id: merchant.id,
                                                                                              net: net))
    [done.id, T.must(done.acquirer_reference)]
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

  # Dispute events in the outbox, oldest first, as their envelopes.
  def dispute_events
    app_db[:events].where(Sequel.like(:type, 'charge.dispute.%')).order(:seq)
                   .map { |row| Clearinghouse::Events.envelope(row).merge('merchant_id' => row[:merchant_id]) }
  end

  def dispute_event_types
    dispute_events.map { |event| event['type'] }
  end
end
