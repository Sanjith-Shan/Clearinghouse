# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Risk::Monotonic::Manual do
  it 'only moves forward' do
    clock = described_class.new(start: 5.0)
    expect(clock.advance(1.5)).to eq(6.5)
    expect { clock.advance(-1.0) }.to raise_error(ArgumentError)
  end
end
