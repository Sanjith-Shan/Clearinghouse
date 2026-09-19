# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Clock do
  describe Clearinghouse::Clock::Test do
    subject(:clock) { described_class.new(start: Time.utc(2026, 3, 1)) }

    it 'stays still until advanced' do
      first = clock.now
      expect(clock.now).to eq(first)
    end

    it 'advances by seconds' do
      clock.advance(2 * Clearinghouse::Clock::SECONDS_PER_DAY)
      expect(clock.now).to eq(Time.utc(2026, 3, 3))
    end

    it 'advances to a time' do
      clock.advance_to(Time.utc(2026, 3, 10, 12))
      expect(clock.now).to eq(Time.utc(2026, 3, 10, 12))
    end

    it 'refuses to go backwards' do
      expect { clock.advance(-1) }.to raise_error(Clearinghouse::Clock::Test::BackwardsError)
      expect { clock.advance_to(Time.utc(2026, 2, 1)) }.to raise_error(Clearinghouse::Clock::Test::BackwardsError)
      expect(clock.now).to eq(Time.utc(2026, 3, 1))
    end

    it 'returns UTC' do
      expect(described_class.new(start: Time.new(2026, 1, 1, 0, 0, 0, '+05:00')).now.utc?).to be(true)
    end
  end

  describe Clearinghouse::Clock::Real do
    it 'tracks the wall clock in UTC' do
      now = described_class.new.now
      expect(now.utc?).to be(true)
      expect((now - Time.now).abs).to be < 5
    end
  end

  describe '.from_env' do
    it 'is the wall clock unless a test or experiment asks to run ahead' do
      expect(described_class.from_env({})).to be_a(Clearinghouse::Clock::Real)
      ahead = described_class.from_env('CLEARINGHOUSE_ENV' => 'experiment', 'CLEARINGHOUSE_CLOCK_AHEAD_S' => '86400')
      expect(ahead.now - Time.now).to be_within(5).of(86_400)
    end

    it 'refuses to run ahead anywhere else' do
      expect { described_class.from_env('CLEARINGHOUSE_CLOCK_AHEAD_S' => '86400') }
        .to raise_error(Clearinghouse::Clock::NotAllowedError)
      expect { described_class.from_env('CLEARINGHOUSE_ENV' => 'production', 'CLEARINGHOUSE_CLOCK_AHEAD_S' => '1') }
        .to raise_error(Clearinghouse::Clock::NotAllowedError)
    end
  end
end
