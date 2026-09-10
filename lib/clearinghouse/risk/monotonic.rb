# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Risk
    # Elapsed real time, in seconds, for deadlines and the circuit breaker's cool-down.
    #
    # This is deliberately not a Clearinghouse::Clock. The simulated clock answers
    # "what time is it for the payment", and it stands still in tests and jumps days
    # at a time in replays. A breaker timed by it would either never cool down (a
    # test clock nobody advances) or cool down instantly (a replay that skips a
    # day between two payments). The breaker protects a real process over a real
    # network, so it waits in real time. It is also not Time.now, which NTP can step
    # backwards; a monotonic clock only moves forward.
    module Monotonic
      extend T::Sig
      extend T::Helpers

      interface!

      sig { abstract.returns(Float) }
      def now; end

      # CLOCK_MONOTONIC, for production and for anything that waits on a socket.
      class Real
        extend T::Sig
        include Monotonic

        sig { override.returns(Float) }
        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
        end
      end

      # A monotonic clock a test moves by hand, so breaker tests need no sleeps.
      class Manual
        extend T::Sig
        include Monotonic

        sig { params(start: Float).void }
        def initialize(start: 1000.0)
          @now = start
          @mutex = Mutex.new
        end

        sig { override.returns(Float) }
        def now
          @mutex.synchronize { @now }
        end

        sig { params(seconds: Float).returns(Float) }
        def advance(seconds)
          raise ArgumentError, "cannot advance by #{seconds}s" if seconds.negative?

          @mutex.synchronize { @now += seconds }
        end
      end
    end
  end
end
