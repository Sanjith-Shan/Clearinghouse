# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Risk
    # Stops calling RiskGate once it is clearly down, so a dead dependency costs each
    # confirm nothing instead of a full deadline.
    #
    # Closed: calls go through. It opens on either of two signals: `consecutive`
    # failures in a row (fast to notice a hard outage), or a failure rate at or above
    # `failure_rate` over the last `window` seconds once at least `min_calls` calls
    # were seen (notices a brownout where every other call times out, which never
    # produces a long unbroken run).
    #
    # Open: every call is refused without touching the network, for `cooldown`
    # seconds.
    #
    # Half-open: after the cool-down, exactly one caller gets a probe permit. Every
    # other caller is still refused while it is in flight. The probe's success closes
    # the breaker with clean statistics; its failure opens it for another cool-down.
    #
    # Thread-safe: every transition happens under one mutex. The mutex is held only
    # for bookkeeping, never across the network call.
    class CircuitBreaker
      extend T::Sig

      # Where the breaker is. See the class comment.
      class State < T::Enum
        enums do
          Closed = new('closed')
          Open = new('open')
          HalfOpen = new('half_open')
        end
      end

      # Permission to make one call. `generation` ties the result back to the breaker
      # state it was issued in, so a slow call that started before the breaker opened
      # cannot close it, or count twice, when it finally returns.
      class Permit < T::Struct
        const :generation, Integer
        const :probe, T::Boolean
      end

      # One state change, for logs and for experiment 9's phase timeline.
      class Transition < T::Struct
        const :from, State
        const :to, State
        const :at, Float
        const :why, String
      end

      Bucket = Struct.new(:start, :calls, :failures)

      BUCKETS = 10

      sig { returns(Integer) }
      attr_reader :consecutive, :min_calls

      sig { returns(Float) }
      attr_reader :failure_rate, :window, :cooldown

      sig do
        params(clock: Monotonic, consecutive: Integer, failure_rate: Float, window: Float, min_calls: Integer,
               cooldown: Float, on_transition: T.nilable(T.proc.params(transition: Transition).void)).void
      end
      def initialize(clock: Monotonic::Real.new, consecutive: 5, failure_rate: 0.5, window: 10.0, min_calls: 20,
                     cooldown: 2.0, on_transition: nil)
        raise ArgumentError, 'consecutive must be >= 1' if consecutive < 1
        raise ArgumentError, 'failure_rate must be in (0, 1]' unless failure_rate.positive? && failure_rate <= 1
        raise ArgumentError, 'window and cooldown must be positive' unless window.positive? && cooldown.positive?

        @clock = clock
        @consecutive = consecutive
        @failure_rate = failure_rate
        @window = window
        @min_calls = min_calls
        @cooldown = cooldown
        @on_transition = on_transition
        @mutex = Mutex.new
        @state = T.let(State::Closed, State)
        @generation = 0
        @opened_at = T.let(0.0, Float)
        @probe_out = false
        @run = 0
        @buckets = T.let(Array.new(BUCKETS) { Bucket.new(-Float::INFINITY, 0, 0) }, T::Array[Bucket])
      end

      # The state as a caller would find it now: an open breaker whose cool-down has
      # passed reads as half-open even before anyone asks for a permit.
      sig { returns(State) }
      def state
        @mutex.synchronize do
          @state == State::Open && cooled_down? ? State::HalfOpen : @state
        end
      end

      # A permit to call, or nil when the call must not be made.
      sig { returns(T.nilable(Permit)) }
      def acquire
        @mutex.synchronize do
          case @state
          when State::Closed then Permit.new(generation: @generation, probe: false)
          when State::Open
            next nil unless cooled_down?

            transition(State::HalfOpen, 'cool-down elapsed')
            probe_permit
          else
            @probe_out ? nil : probe_permit
          end
        end
      end

      # Reports how the permitted call went. `success` means RiskGate is alive and
      # answering, not that it said allow.
      sig { params(permit: Permit, success: T::Boolean).void }
      def record(permit, success:)
        @mutex.synchronize do
          next unless permit.generation == @generation

          permit.probe ? record_probe(success) : record_call(success)
        end
      end

      private

      sig { returns(Permit) }
      def probe_permit
        @probe_out = true
        Permit.new(generation: @generation, probe: true)
      end

      sig { params(success: T::Boolean).void }
      def record_probe(success)
        @probe_out = false
        if success
          transition(State::Closed, 'probe succeeded')
        else
          open!('probe failed')
        end
      end

      sig { params(success: T::Boolean).void }
      def record_call(success)
        return unless @state == State::Closed

        bucket = current_bucket
        bucket.calls += 1
        if success
          @run = 0
          return
        end

        bucket.failures += 1
        @run += 1
        if @run >= @consecutive
          open!("#{@run} consecutive failures")
        elsif (rate = windowed_rate)
          open!(format('failure rate %<rate>.2f over %<window>.0fs', rate: rate, window: @window))
        end
      end

      # The failure rate over the window, or nil if it is under the threshold or
      # there were too few calls to judge.
      sig { returns(T.nilable(Float)) }
      def windowed_rate
        horizon = @clock.now - @window
        live = @buckets.select { |b| b.start > horizon }
        calls = live.sum(&:calls)
        return nil if calls < @min_calls

        rate = live.sum(&:failures).fdiv(calls)
        rate >= @failure_rate ? rate : nil
      end

      # The window is a ring of BUCKETS time slices; a slice older than the window is
      # reset when its slot comes round again, so the cost per call is constant.
      sig { returns(Bucket) }
      def current_bucket
        width = @window / BUCKETS
        slice = (@clock.now / width).floor
        bucket = T.must(@buckets[slice % BUCKETS])
        start = slice * width
        if bucket.start != start
          bucket.start = start
          bucket.calls = 0
          bucket.failures = 0
        end
        bucket
      end

      sig { params(why: String).void }
      def open!(why)
        @opened_at = @clock.now
        transition(State::Open, why)
      end

      sig { returns(T::Boolean) }
      def cooled_down?
        @clock.now - @opened_at >= @cooldown
      end

      # Every transition starts a new generation and clean statistics.
      sig { params(to: State, why: String).void }
      def transition(to, why)
        from = @state
        @state = to
        @generation += 1
        @run = 0
        @probe_out = false
        @buckets.each { |b| b.start = -Float::INFINITY }
        @on_transition&.call(Transition.new(from: from, to: to, at: @clock.now, why: why))
      end
    end
  end
end
