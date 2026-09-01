# typed: true
# frozen_string_literal: true

module AcquirerSim
  # Knobs set through POST /admin/config. Defaults are the quiet, fast acquirer the
  # unit tests want: no latency, no errors, no drops.
  class Config < T::Struct
    extend T::Sig

    prop :seed, Integer, default: 1
    prop :latency_p50_ms, Float, default: 0.0
    prop :latency_p99_ms, Float, default: 0.0
    prop :error_rate, Float, default: 0.0
    prop :drop_after_commit_rate, Float, default: 0.0
    prop :dispute_after_days, Integer, default: 7

    # Returns a copy of `base` with the fields named in `json` replaced. Validation is
    # strict because a mistyped knob silently ignored would make an experiment measure
    # the wrong thing.
    sig { params(json: T::Hash[String, T.untyped], base: Config).returns(Config) }
    def self.merge(json, base)
      config = base.dup
      json.each do |name, value|
        case name
        when 'seed' then config.seed = integer(name, value, min: 0)
        when 'latency_ms' then apply_latency(config, value)
        when 'error_rate' then config.error_rate = rate(name, value)
        when 'drop_after_commit_rate' then config.drop_after_commit_rate = rate(name, value)
        when 'dispute_after_days' then config.dispute_after_days = integer(name, value, min: 0)
        else raise Params.invalid("unknown config field #{name}", name)
        end
      end
      config
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      {
        'seed' => seed, 'latency_ms' => { 'p50' => latency_p50_ms, 'p99' => latency_p99_ms },
        'error_rate' => error_rate, 'drop_after_commit_rate' => drop_after_commit_rate,
        'dispute_after_days' => dispute_after_days
      }
    end

    sig { params(config: Config, value: T.untyped).void }
    def self.apply_latency(config, value)
      raise Params.invalid('latency_ms must be {"p50": ms, "p99": ms}', 'latency_ms') unless value.is_a?(Hash)

      p50 = number('latency_ms.p50', value.fetch('p50', config.latency_p50_ms))
      p99 = number('latency_ms.p99', value.fetch('p99', [p50, config.latency_p99_ms].max))
      raise Params.invalid('latency_ms.p99 must be >= p50', 'latency_ms') if p99 < p50
      raise Params.invalid('latency_ms.p50 must be positive when p99 is', 'latency_ms') if p50.zero? && p99.positive?

      config.latency_p50_ms = p50
      config.latency_p99_ms = p99
    end

    sig { params(name: String, value: T.untyped, min: Integer).returns(Integer) }
    def self.integer(name, value, min:)
      raise Params.invalid("#{name} must be an integer >= #{min}", name) unless value.is_a?(Integer) && value >= min

      value
    end

    sig { params(name: String, value: T.untyped).returns(Float) }
    def self.number(name, value)
      raise Params.invalid("#{name} must be a number >= 0", name) unless value.is_a?(Numeric) && value >= 0

      value.to_f
    end

    sig { params(name: String, value: T.untyped).returns(Float) }
    def self.rate(name, value)
      rate = number(name, value)
      raise Params.invalid("#{name} must be between 0 and 1", name) if rate > 1

      rate
    end
  end
end
