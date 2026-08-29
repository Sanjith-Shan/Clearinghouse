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
  end
end
