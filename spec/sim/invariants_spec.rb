# typed: false
# frozen_string_literal: true

require_relative 'sim_helper'

# Random sequences of operations against the simulator's books, checking after every
# step that no authorization ever holds more captured than authorized, more refunded
# than captured, or a capture after a void.
RSpec.describe AcquirerSim::Simulator do
  let(:t0) { Time.utc(2026, 1, 1) }

  def expect_invariants(simulator)
    simulator.authorizations.each do |auth|
      expect(auth.captured).to be_between(0, auth.amount)
      expect(auth.refunded).to be_between(0, auth.captured)
      expect(auth.captured).to eq(0) if auth.voided || !auth.approved
    end
  end

  it 'keeps capture <= authorized and refunds <= captured under random operation sequences' do
    g = PropCheck::Generators
    step = g.tuple(g.one_of(g.constant('capture'), g.constant('void'), g.constant('refund'), g.constant('authorize')),
                   g.choose(0..3), g.choose(1..12_000))
    PropCheck.forall(g.array(step, max: 40)) do |steps|
      simulator = described_class.new
      refs = []
      steps.each_with_index do |(type, target, amount), i|
        key = "k#{i}"
        if type == 'authorize' || refs.empty?
          pm = target.zero? ? 'pm_card_chargeDeclined' : 'pm_card_visa'
          op = simulator.submit('authorize', key, { 'payment_method' => pm, 'amount' => 10_000,
                                                    'currency' => 'usd', 'capture' => target == 3 }, t0).operation
          refs << op.acquirer_reference
        else
          simulator.submit(type, key, { 'acquirer_reference' => refs[target % refs.size], 'amount' => amount }, t0)
        end
        expect_invariants(simulator)
      end
    end
  end
end
