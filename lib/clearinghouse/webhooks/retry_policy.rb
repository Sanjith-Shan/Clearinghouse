# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Webhooks
    # When to try a failed delivery again: exponential backoff with full jitter, inside a
    # window of about three simulated days from the moment the delivery was created,
    # which is how long Stripe keeps retrying in live mode.
    #
    # Full jitter (Marc Brooker, "Exponential Backoff And Jitter", AWS Architecture Blog,
    # 2015) draws the delay uniformly from [0, min(cap, base * 2^(n-1))). Without jitter,
    # every delivery that failed during one outage retries at the same instants, and the
    # endpoint that just recovered takes the whole backlog at once. The randomness comes
    # from an injected Random so a seeded test can check the exact schedule.
    #
    # With the defaults (1 minute base, 12 hour cap, 3 day window) a delivery that always
    # fails is attempted about 20 times; retry_policy_spec measures the distribution.
    class RetryPolicy < T::Struct
      extend T::Sig

      const :base, Float, default: 60.0
      const :cap, Float, default: 12.0 * 3600
      const :window, Float, default: 3.0 * Clock::SECONDS_PER_DAY

      # The delay before attempt `attempts + 1`, after `attempts` failed attempts (>= 1).
      sig { params(attempts: Integer, rng: Random).returns(Float) }
      def delay(attempts, rng)
        raise ArgumentError, "attempts must be at least 1, got #{attempts}" if attempts < 1

        # 2^(n-1) overflows nothing in Ruby, but capping the exponent keeps it a small
        # Float instead of a bignum after a few hundred attempts.
        ceiling = [cap, base * (2.0**[attempts - 1, 62].min)].min
        rng.rand * ceiling
      end

      # When to try next, or nil when the next try would fall outside the window and
      # the delivery should be marked failed.
      sig { params(attempts: Integer, now: Time, deadline: Time, rng: Random).returns(T.nilable(Time)) }
      def next_attempt_at(attempts, now:, deadline:, rng:)
        at = now + delay(attempts, rng)
        at > deadline ? nil : at
      end

      sig { params(created_at: Time).returns(Time) }
      def deadline_for(created_at)
        created_at + window
      end
    end
  end
end
