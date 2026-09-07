# typed: true
# frozen_string_literal: true

module ClearinghouseClient
  # When to retry and how long to wait. Pure: no I/O, no clock, randomness injected,
  # so every decision is unit-testable. See docs/design/client.md.
  class RetryPolicy
    extend T::Sig

    DEFAULT_INITIAL_DELAY = 0.5
    DEFAULT_MAX_DELAY = 8.0
    # A server asking us to wait longer than this is asking us to give up for now.
    DEFAULT_MAX_RETRY_AFTER = 60

    RETRYABLE_STATUSES = [409, 429].freeze

    sig { returns(Integer) }
    attr_reader :max_retries

    sig do
      params(max_retries: Integer, rng: Random, initial_delay: Float, max_delay: Float,
             max_retry_after: Integer).void
    end
    def initialize(max_retries:, rng:, initial_delay: DEFAULT_INITIAL_DELAY, max_delay: DEFAULT_MAX_DELAY,
                   max_retry_after: DEFAULT_MAX_RETRY_AFTER)
      raise ArgumentError, "max_retries must be >= 0, got #{max_retries}" if max_retries.negative?

      @max_retries = max_retries
      @rng = rng
      @initial_delay = initial_delay
      @max_delay = max_delay
      @max_retry_after = max_retry_after
    end

    # Whether to send the call again after `retries_done` retries ended in `response`
    # (an error response) or `connection_error` (no response at all).
    #
    # Every retry here is safe because a mutating call reuses its Idempotency-Key on
    # every attempt, so a request that did land is replayed, not repeated. Reads
    # carry no key and are safe to repeat anyway.
    sig do
      params(retries_done: Integer, response: T.nilable(Response),
             connection_error: T.nilable(APIConnectionError)).returns(T::Boolean)
    end
    def retry?(retries_done, response: nil, connection_error: nil)
      return false if retries_done >= max_retries
      return true if connection_error
      return false if response.nil?

      wait = response.retry_after
      return false if wait && wait > @max_retry_after

      # The server knows things the status code cannot say (whether a 500 happened
      # after a side effect, whether a 409's first request is still running), so its
      # verdict wins over the heuristic in both directions.
      verdict = response.should_retry
      return verdict unless verdict.nil?

      RETRYABLE_STATUSES.include?(response.status) || response.status >= 500
    end

    # Seconds to sleep before retry number `retry_number` (1 for the first retry).
    #
    # Exponential backoff with full jitter: a uniform draw from [0, min(cap, base *
    # 2^(n-1))). Full jitter spreads a crowd of clients that failed at the same moment
    # across the whole window instead of sending them back in lockstep. A Retry-After
    # from the server is a floor: we never come back sooner than it asked.
    sig { params(retry_number: Integer, retry_after: T.nilable(Integer)).returns(Float) }
    def delay(retry_number, retry_after: nil)
      raise ArgumentError, "retry_number starts at 1, got #{retry_number}" if retry_number < 1

      ceiling = [@max_delay, @initial_delay * (2**(retry_number - 1))].min
      jittered = Float(@rng.rand * ceiling)
      floor = retry_after.to_f
      return floor if floor > jittered

      jittered
    end
  end
end
