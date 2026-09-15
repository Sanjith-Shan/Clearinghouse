# typed: false
# frozen_string_literal: true

require_relative 'model_helper'

RSpec.describe Clearinghouse::Testing::Model::Shrinker, :model do
  # A fake system whose "bug" needs a create, a later confirm of the same object,
  # and a large enough amount: the shrinker must keep exactly those.
  def failure_when(commands)
    created = {}
    commands.each_with_index do |c, i|
      created[c.args[:intent]] = c.args[:amount] if c.op == :create_intent
      next unless c.op == :confirm && created.fetch(c.args[:intent], 0) >= 300

      violation = ModelTesting::Checks::Violation.new(check: :balances, details: ['boom'])
      return ModelTesting::Failure.new(index: i, command: c, violation: violation)
    end
    nil
  end

  let(:noise) { Array.new(12) { |i| cmd(:advance_clock, hours: i + 1) } }
  let(:commands) do
    noise.first(4) + [intent_cmd('pi_1', 4321), intent_cmd('pi_2', 999)] + noise.last(8) +
      [cmd(:confirm, intent: 'pi_2', payment_method: 'pm_card_visa')] + noise.first(3)
  end

  it 'removes every command the failure does not need and shrinks the amount to the boundary' do
    shrinker = described_class.new(->(cs) { failure_when(cs) })
    shrunk, failure = shrinker.shrink(commands, failure_when(commands))
    expect(shrunk.map(&:to_ruby)).to eq([intent_cmd('pi_2', 300).to_ruby,
                                         'h.confirm(intent: "pi_2", payment_method: "pm_card_visa")'])
    expect(failure.index).to eq(1)
  end

  it 'does not trade the failure for a different one' do
    other = lambda do |cs|
      found = failure_when(cs)
      next found if found && cs.length > 3

      other_violation = ModelTesting::Checks::Violation.new(check: :zero_sum, details: ['other'])
      found && ModelTesting::Failure.new(index: found.index, command: found.command, violation: other_violation)
    end
    shrunk, failure = described_class.new(other).shrink(commands, failure_when(commands))
    expect(failure.violation.check).to eq(:balances)
    expect(shrunk.length).to be > 3
  end

  it 'stops after its attempt budget' do
    shrinker = described_class.new(->(cs) { failure_when(cs) }, max_attempts: 3)
    shrinker.shrink(commands, failure_when(commands))
    expect(shrinker.attempts).to eq(3)
  end
end
