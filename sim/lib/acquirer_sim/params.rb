# typed: true
# frozen_string_literal: true

require 'digest'
require 'json'

module AcquirerSim
  # A request the simulator refuses without recording anything. The status and code
  # go straight onto the wire as `{"error": code, "message": ..., "param": ...}`.
  class RequestError < StandardError
    extend T::Sig

    sig { returns(Integer) }
    attr_reader :status

    sig { returns(String) }
    attr_reader :code

    sig { returns(T.nilable(String)) }
    attr_reader :param

    sig { params(status: Integer, code: String, message: String, param: T.nilable(String)).void }
    def initialize(status, code, message, param: nil)
      super(message)
      @status = status
      @code = code
      @param = param
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      { 'error' => code, 'message' => message, 'param' => param }.compact
    end
  end

  # Strict readers for request bodies. The simulator is a test fixture, so a wrong
  # type is always a caller bug and gets a 400 naming the field, never a coercion.
  module Params
    extend T::Sig

    MAX_KEY_LENGTH = 255

    sig { params(body: String).returns(T::Hash[String, T.untyped]) }
    def self.parse_json(body)
      return {} if body.strip.empty?

      parsed = JSON.parse(body)
      raise invalid('request body must be a JSON object') unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise invalid("request body is not JSON: #{e.message}")
    end

    sig { params(params: T::Hash[String, T.untyped], name: String).returns(String) }
    def self.string(params, name)
      value = params[name]
      raise invalid("#{name} must be a non-empty string", name) unless value.is_a?(String) && !value.empty?

      value
    end

    sig { params(params: T::Hash[String, T.untyped], name: String).returns(T.nilable(String)) }
    def self.optional_string(params, name)
      params.key?(name) && !params[name].nil? ? string(params, name) : nil
    end

    sig { params(params: T::Hash[String, T.untyped], name: String).returns(Integer) }
    def self.positive_amount(params, name = 'amount')
      value = params[name]
      unless value.is_a?(Integer) && value.positive?
        raise invalid("#{name} must be a positive integer in minor units",
                      name)
      end

      value
    end

    sig { params(params: T::Hash[String, T.untyped], name: String, default: T::Boolean).returns(T::Boolean) }
    def self.boolean(params, name, default:)
      return default unless params.key?(name)

      value = params[name]
      raise invalid("#{name} must be true or false", name) unless [true, false].include?(value)

      value
    end

    sig { params(params: T::Hash[String, T.untyped], name: String).returns(String) }
    def self.currency(params, name = 'currency')
      Clearinghouse::Currency.normalize(string(params, name))
    rescue Clearinghouse::Currency::UnknownCurrencyError
      raise invalid("unknown currency #{params[name].inspect}", name)
    end

    sig { params(params: T::Hash[String, T.untyped], name: String).returns(T.nilable(String)) }
    def self.optional_currency(params, name = 'currency')
      params[name].nil? ? nil : currency(params, name)
    end

    sig { params(value: T.nilable(String)).returns(String) }
    def self.idempotency_key(value)
      if value.nil? || value.empty? || value.length > MAX_KEY_LENGTH
        raise RequestError.new(400, 'idempotency_key_required',
                               "Idempotency-Key header is required (1 to #{MAX_KEY_LENGTH} characters)")
      end

      value
    end

    # Simulated time is the caller's, carried on every request. There is no fallback
    # to the wall clock: a request without it is refused, so a forgotten header shows
    # up as a failing test instead of as behaviour that depends on when CI ran.
    sig { params(value: T.nilable(String)).returns(Time) }
    def self.sim_time(value)
      raise RequestError.new(400, 'sim_time_required', 'Sim-Time header (ISO 8601) is required') if value.nil?

      Time.iso8601(value).utc
    rescue ArgumentError
      raise RequestError.new(400, 'sim_time_invalid', "Sim-Time is not ISO 8601: #{value.inspect}")
    end

    # Canonical JSON (keys sorted at every depth) so the fingerprint does not depend
    # on the order the client happened to serialize fields in.
    sig { params(value: T.untyped).returns(T.untyped) }
    def self.canonical(value)
      case value
      when Hash then value.sort_by { |k, _| k.to_s }.to_h { |k, v| [k.to_s, canonical(v)] }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    sig { params(type: String, params: T::Hash[String, T.untyped]).returns(String) }
    def self.fingerprint(type, params)
      Digest::SHA256.hexdigest("#{type}\n#{JSON.generate(canonical(params))}")
    end

    sig { params(message: String, param: T.nilable(String)).returns(RequestError) }
    def self.invalid(message, param = nil)
      RequestError.new(400, 'invalid_request', message, param: param)
    end
  end
end
