# typed: false
# frozen_string_literal: true

require_relative '../../lib/clearinghouse/testing/model'

ModelTesting = Clearinghouse::Testing::Model

# Builders for the model-based testing specs.
module ModelSpecHelpers
  M = ModelTesting

  def cmd(operation, **args)
    M::Command.new(op: operation, args: args)
  end

  # The usual opening: one merchant on the default US card fee.
  def merchant_cmd(name = 'm1', rate: 290_000, fixed: { 'usd' => 30 })
    cmd(:create_merchant, merchant: name, fee_rate_scaled: rate, fee_fixed: fixed)
  end

  def intent_cmd(name, amount, currency: 'usd', capture_method: 'automatic', merchant: 'm1')
    cmd(:create_intent, intent: name, merchant: merchant, amount: amount, currency: currency,
                        capture_method: capture_method)
  end

  def success(**fields)
    M::Outcome.success(**fields)
  end

  def error(code, decline_code: nil)
    M::Outcome.error(code, decline_code: decline_code)
  end

  def run_all(sut, commands)
    commands.map { |c| sut.apply(c) }
  end
end

RSpec.configure do |config|
  config.include ModelSpecHelpers, :model
end
