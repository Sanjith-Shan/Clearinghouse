# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Webhooks
    # The rules of a per-endpoint circuit breaker, as pure functions over its state.
    # Breakers persists the state on the endpoint row and applies these rules under a
    # row lock, so every worker in every process sees one breaker per endpoint.
    #
    #   closed    --threshold consecutive failures-->  open (until retry_at)
    #   open      --retry_at reached, at claim time--> half_open
    #   half_open --the one probe succeeds-->          closed
    #   half_open --the probe fails-->                 open, with a longer cool-down
    #
    # While open, no delivery to the endpoint is claimed, so a dead endpoint costs no
    # worker time at all, and its deliveries do not burn retry attempts. Half-open
    # admits exactly one delivery (the in-flight cap drops to 1). Each failed probe
    # doubles the cool-down, up to max_cooldown, so an endpoint that is down for a day
    # is probed every ten minutes rather than every thirty seconds.
    #
    # A success in any state closes the breaker: a delivery claimed before the breaker
    # opened that comes back 200 is as good a probe as any.
    class CircuitBreaker < T::Struct
      extend T::Sig

      # The persisted state of one endpoint's breaker.
      class State < T::Struct
        const :state, String
        const :consecutive_failures, Integer
        const :reopens, Integer
        const :retry_at, T.nilable(Time)

        CLOSED = T.let(new(state: 'closed', consecutive_failures: 0, reopens: 0, retry_at: nil), State)
      end

      const :failure_threshold, Integer, default: 5
      const :cooldown, Float, default: 30.0
      const :max_cooldown, Float, default: 600.0

      sig { params(current: State, now: Time).returns(State) }
      def after_failure(current, now:)
        failures = current.consecutive_failures + 1
        case current.state
        when 'half_open'
          reopens = current.reopens + 1
          State.new(state: 'open', consecutive_failures: failures, reopens: reopens,
                    retry_at: now + cooldown_after(reopens))
        when 'closed'
          if failures >= failure_threshold
            State.new(state: 'open', consecutive_failures: failures, reopens: 0, retry_at: now + cooldown)
          else
            State.new(state: 'closed', consecutive_failures: failures, reopens: 0, retry_at: nil)
          end
        else
          # Already open: a delivery claimed before it opened failed late. Count it,
          # but do not push the retry time out.
          State.new(state: current.state, consecutive_failures: failures, reopens: current.reopens,
                    retry_at: current.retry_at)
        end
      end

      sig { returns(State) }
      def after_success = State::CLOSED

      # At claim time: nil if nothing may be claimed now, otherwise the state to claim
      # under (an open breaker whose cool-down is over becomes half_open).
      sig { params(current: State, now: Time).returns(T.nilable(State)) }
      def admit(current, now:)
        return current unless current.state == 'open'

        retry_at = current.retry_at
        return nil if retry_at && now < retry_at

        State.new(state: 'half_open', consecutive_failures: current.consecutive_failures,
                  reopens: current.reopens, retry_at: nil)
      end

      # How many deliveries may be in flight to an endpoint in this state.
      sig { params(current: State, max_in_flight: Integer).returns(Integer) }
      def in_flight_limit(current, max_in_flight)
        case current.state
        when 'closed' then max_in_flight
        when 'half_open' then 1
        else 0
        end
      end

      sig { params(reopens: Integer).returns(Float) }
      def cooldown_after(reopens)
        [max_cooldown, cooldown * (2.0**[reopens, 30].min)].min
      end
    end
  end
end
