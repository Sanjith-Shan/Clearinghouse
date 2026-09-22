# typed: strict
# frozen_string_literal: true

module Clearinghouse
  # Every component reads time through a Clock, never Time.now. Settlement,
  # available_on, webhook retries and key expiry all span simulated days, and the
  # only way to test them is a clock the test controls.
  module Clock
    extend T::Sig
    extend T::Helpers

    interface!

    sig { abstract.returns(Time) }
    def now; end

    # The wall clock, for production mode.
    class Real
      extend T::Sig
      include Clock

      sig { override.returns(Time) }
      def now
        Time.now.utc
      end
    end

    # A clock that only moves when told to, modelled on Stripe's test clocks.
    # It never goes backwards, because nothing scheduled against it could cope.
    class Test
      extend T::Sig
      include Clock

      class BackwardsError < Clearinghouse::Error; end

      sig { params(start: Time).void }
      def initialize(start: Time.utc(2026, 1, 1))
        @now = T.let(start.utc, Time)
        @mutex = T.let(Mutex.new, Thread::Mutex)
      end

      sig { override.returns(Time) }
      def now
        @mutex.synchronize { @now }
      end

      sig { params(seconds: Numeric).returns(Time) }
      def advance(seconds)
        raise BackwardsError, "cannot advance by #{seconds}s" if seconds.negative?

        @mutex.synchronize { @now += seconds }
      end

      sig { params(time: Time).returns(Time) }
      def advance_to(time)
        @mutex.synchronize do
          raise BackwardsError, "#{time} is before #{@now}" if time < @now

          @now = time.utc
        end
      end
    end

    SECONDS_PER_DAY = 86_400

    # The wall clock, a fixed distance ahead. Experiment 2 runs bin/poller on one so
    # that a dispute the acquirer opens seven days after capture is due now, without
    # a test clock (a separate process cannot share one) and without waiting a week.
    class Ahead
      extend T::Sig
      include Clock

      sig { params(seconds: Numeric).void }
      def initialize(seconds)
        @seconds = seconds
        @real = T.let(Real.new, Real)
      end

      sig { override.returns(Time) }
      def now
        @real.now + @seconds
      end
    end

    class NotAllowedError < Clearinghouse::Error; end

    # The clock a background process runs on: the wall clock, unless
    # CLEARINGHOUSE_CLOCK_AHEAD_S asks for one ahead of it. That is refused unless
    # CLEARINGHOUSE_ENV is test or experiment, loudly rather than ignored, because a
    # production process on a shifted clock would book money on the wrong dates.
    sig { params(env: T::Hash[String, String]).returns(Clock) }
    def self.from_env(env = ENV.to_h)
      ahead = env['CLEARINGHOUSE_CLOCK_AHEAD_S'].to_s
      return Real.new if ahead.empty?
      unless %w[test experiment].include?(env['CLEARINGHOUSE_ENV'])
        raise NotAllowedError,
              'CLEARINGHOUSE_CLOCK_AHEAD_S is only allowed when CLEARINGHOUSE_ENV is test or experiment'
      end

      Ahead.new(Float(ahead))
    end
  end
end
