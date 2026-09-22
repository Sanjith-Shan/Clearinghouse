# typed: false
# frozen_string_literal: true

require_relative 'db'
require_relative '../sim/sim_helper'

DBHelper.clean_tables('acquirer_cursors', 'processed_notifications', 'disputes', 'merchants',
                      'settlement_files', 'settlement_lines', 'reconciliation_exceptions')

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

  # A hook that crashes once, the first time `point` is reached. The poller also
  # passes the notification type, the disputes service does not.
  def crash_once_at(point)
    fired = false
    lambda do |reached, _type = nil|
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
    base.let(:merchant_and_key) do
      Clearinghouse::Merchants.create(app_db, clock: clock, name: 'Rocket Rides', api_version: '2026-09-01')
    end
    base.let(:merchant) { merchant_and_key.first }
    base.let(:merchant_key) { merchant_and_key.last }
  end

  def available(currency = 'usd')
    balance_of("merchant:#{merchant.id}:available", currency)
  end

  # The API, in process (no socket), wired to the simulator with `at_clock`, and a
  # request as the merchant. Payments and refunds in these specs go through it, so
  # they run the same idempotent flows and postings as production.
  def api_request(method, path, params = {}, at_clock: clock)
    acquirer = at_clock.equal?(clock) ? client : Clearinghouse::Acquirer::Client.new(clock: at_clock, base_url: sim.url)
    deps = Clearinghouse::Api::Dependencies.new(db: app_db, clock: at_clock, acquirer: acquirer)
    response = Rack::MockRequest.new(Clearinghouse::Api.rack_app(deps)).request(
      method.to_s.upcase, path,
      input: Rack::Utils.build_nested_query(params), 'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
      'HTTP_AUTHORIZATION' => "Bearer #{merchant_key}", 'HTTP_IDEMPOTENCY_KEY' => SecureRandom.uuid
    )
    body = JSON.parse(response.body)
    raise "#{method} #{path} failed: #{response.status} #{response.body}" unless response.status == 200

    body
  end

  # Creates and confirms an automatic-capture PaymentIntent through the API, then
  # releases its net to available with the payouts work's availability job, as if
  # the payout delay had passed. Returns [payment_intent id, acquirer reference].
  # `at_clock` makes the payment with another clock (a lagging one, say).
  def captured_payment(amount: 10_000, currency: 'usd', payment_method: 'pm_card_disputeFraudulent', at_clock: clock)
    intent = api_request(:post, '/v1/payment_intents', { amount: amount, currency: currency,
                                                         payment_method: payment_method }, at_clock: at_clock)
    api_request(:post, "/v1/payment_intents/#{intent.fetch('id')}/confirm", {}, at_clock: at_clock)
    later = Clearinghouse::Clock::Test.new(start: at_clock.now + (30 * SettlementHelpers::DAY))
    Clearinghouse::Balances::Availability.release_due!(app_db, clock: later)
    [intent.fetch('id'), app_db[:payment_intents].where(id: intent.fetch('id')).get(:acquirer_reference)]
  end

  # A refund through the API. Returns [refund id, the acquirer's operation id for it].
  def refunded(payment, amount)
    refund = api_request(:post, '/v1/refunds', { payment_intent: payment, amount: amount })
    [refund.fetch('id'), app_db[:refunds].where(id: refund.fetch('id')).get(:acquirer_operation_id)]
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

# The reconciler wired to the simulator, and the day-by-day moves its specs make.
module ReconcilerHelpers
  def self.included(base)
    base.let(:ingestor) { Clearinghouse::Reconciliation::Ingestor.new(db: app_db, client: client, clock: clock) }
  end

  # Moves the clock to 00:30 on `date`, when the day's file is fetched.
  def on(date)
    clock.advance_to(Time.utc(date.year, date.month, date.day, 0, 30))
  end

  def ingest(date, inject: [])
    on(date)
    ingestor.ingest(date, inject: inject)
  end

  def exceptions(reason = nil)
    scope = app_db[:reconciliation_exceptions]
    scope = scope.where(reason: reason) if reason
    scope.order(:created_at, :id).all
  end

  def open_flows
    Clearinghouse::Ledger::Clearing.report(app_db, as_of: clock.now, slas: {}).open_flows
                                   .to_h { |flow| [flow.flow_id, flow.unexplained] }
  end

  def manifest(date)
    JSON.parse(Net::HTTP.get(URI("#{sim.url}/admin/settlement_files/#{date.iso8601}/manifest")))
  end
end
