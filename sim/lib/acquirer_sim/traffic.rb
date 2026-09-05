# typed: true
# frozen_string_literal: true

module AcquirerSim
  # Decides, per request, how the network misbehaves: how long to stall, whether to
  # answer 503 without doing anything, and whether to commit and then hang up. Draws
  # come from one seeded RNG in request order, so a fixed seed and a fixed sequence of
  # requests misbehave identically every run. Callers hold the simulator's mutex.
  class Traffic
    extend T::Sig

    # z for the 99th percentile of a standard normal, used to fit a lognormal to p50
    # and p99: ln(p99) = ln(p50) + Z99 * sigma.
    Z99 = 2.3263478740408408

    # What happens to one request.
    class Decision < T::Struct
      const :latency_seconds, Float
      const :unavailable, T::Boolean
      const :drop_after_commit, T::Boolean
    end

    sig { params(config: Config).void }
    def initialize(config)
      @config = config
      @rng = T.let(Random.new(config.seed), Random)
    end

    # Always draws four numbers, whatever the config, so changing one knob does not
    # shift the stream the others see.
    sig { returns(Decision) }
    def decide
      radius_draw = 1.0 - @rng.rand # (0, 1], so the log below is finite
      angle_draw = @rng.rand
      error_draw = @rng.rand
      drop_draw = @rng.rand
      Decision.new(latency_seconds: latency_ms(radius_draw, angle_draw) / 1000.0,
                   unavailable: error_draw < @config.error_rate,
                   drop_after_commit: drop_draw < @config.drop_after_commit_rate)
    end

    private

    # A lognormal through the configured p50 and p99, from a Box-Muller normal.
    # Latency in real systems has a long right tail and never goes negative, which
    # is what the lognormal gives and a normal does not.
    sig { params(radius_draw: Float, angle_draw: Float).returns(Float) }
    def latency_ms(radius_draw, angle_draw)
      p50 = @config.latency_p50_ms
      return 0.0 if p50.zero?

      sigma = Math.log(@config.latency_p99_ms / p50) / Z99
      z = Math.sqrt(-2.0 * Math.log(radius_draw)) * Math.cos(2.0 * Math::PI * angle_draw)
      p50 * Math.exp(sigma * z)
    end
  end
end
