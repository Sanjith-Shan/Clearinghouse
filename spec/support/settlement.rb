# typed: false
# frozen_string_literal: true

require_relative 'db'
require_relative '../sim/sim_helper'

DBHelper.clean_tables('acquirer_cursors', 'processed_notifications')

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
