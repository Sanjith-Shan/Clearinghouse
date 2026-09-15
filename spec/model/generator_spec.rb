# typed: false
# frozen_string_literal: true

require_relative 'model_helper'

RSpec.describe Clearinghouse::Testing::Model::Generator, :model do
  it 'makes the same commands from the same seed' do
    sequence = lambda do |seed|
      model = ModelTesting::ReferenceModel.new
      gen = described_class.new(Random.new(seed))
      Array.new(60) { gen.next_command(model).tap { |c| model.apply(c) }.to_ruby }
    end
    first = sequence.call(3)
    expect(sequence.call(3)).to eq(first)
    expect(sequence.call(4)).not_to eq(first)
  end

  it 'starts with a merchant on the default fee' do
    command = described_class.new(Random.new(1)).next_command(ModelTesting::ReferenceModel.new)
    expect(command).to have_attributes(op: :create_merchant)
    expect(command.args).to eq(merchant: 'm1', fee_rate_scaled: 290_000, fee_fixed: { 'usd' => 30 })
  end
end
