# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Risk
    # What Clearinghouse sends RiskGate about one confirm attempt.
    #
    # `created` is the intent's creation time in simulated unix seconds, not the time
    # of the call. RiskGate keys its velocity windows on event time, and keeping the
    # body a pure function of the intent means a retry under the same Idempotency-Key
    # sends the same bytes.
    class AssessRequest < T::Struct
      extend T::Sig

      const :payment_id, String
      const :created, Integer
      const :amount, Money
      const :risk_fields, T::Hash[String, T.untyped], default: {}

      sig { params(attempt: Integer).returns(String) }
      def idempotency_key(attempt)
        "#{payment_id}:#{attempt}"
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_json_hash
        { 'payment_id' => payment_id, 'created' => created, 'amount' => amount.amount,
          'currency' => amount.currency, 'risk_fields' => risk_fields }
      end
    end

    # RiskGate answered. Every field was checked against the contract in
    # docs/design/interfaces.md before this was built; a response that fails the
    # check is Unavailable(malformed), never a half-filled Assessment.
    class Assessment < T::Struct
      extend T::Sig

      DECISIONS = %w[allow block review].freeze
      SCORE_RANGE = T.let(0..99, T::Range[Integer])
      MAX_REASONS = 3

      class Invalid < Clearinghouse::Error; end

      const :assessment_id, String
      const :decision, String
      const :risk_score, Integer
      const :matched_rule, T.nilable(String)
      const :reasons, T::Array[String]
      const :ruleset_version, String
      # RiskGate said this was a replay of an earlier call with the same key.
      const :replayed, T::Boolean, default: false

      sig { params(json: T.untyped, replayed: T::Boolean).returns(Assessment) }
      def self.from_json(json, replayed: false)
        raise Invalid, 'body is not an object' unless json.is_a?(Hash)

        new(assessment_id: nonempty_string(json, 'assessment_id'), decision: decision(json),
            risk_score: score(json), matched_rule: matched_rule(json), reasons: reasons(json),
            ruleset_version: ruleset_version(json), replayed: replayed)
      end

      sig { params(json: T::Hash[String, T.untyped], key: String).returns(String) }
      def self.nonempty_string(json, key)
        value = json[key]
        raise Invalid, "#{key} must be a non-empty string" unless value.is_a?(String) && !value.empty?

        value
      end

      sig { params(json: T::Hash[String, T.untyped]).returns(String) }
      def self.decision(json)
        value = json['decision']
        raise Invalid, "decision #{value.inspect} is not allow, block or review" unless DECISIONS.include?(value)

        value
      end

      sig { params(json: T::Hash[String, T.untyped]).returns(Integer) }
      def self.score(json)
        value = json['risk_score']
        # Range#include? is true for 50.5, so the class is checked too.
        unless value.is_a?(Integer) && SCORE_RANGE.include?(value)
          raise Invalid, "risk_score #{value.inspect} is not an integer in 0..99"
        end

        value
      end

      sig { params(json: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
      def self.matched_rule(json)
        value = json['matched_rule']
        raise Invalid, 'matched_rule must be a string or null' unless value.nil? || value.is_a?(String)

        value
      end

      sig { params(json: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def self.reasons(json)
        value = json['reasons']
        unless value.is_a?(Array) && value.length <= MAX_REASONS && value.all?(String)
          raise Invalid, "reasons must be at most #{MAX_REASONS} strings"
        end

        value
      end

      # RiskGate may version rule sets by number or by name; both are kept as text.
      sig { params(json: T::Hash[String, T.untyped]).returns(String) }
      def self.ruleset_version(json)
        value = json['ruleset_version']
        return value.to_s if value.is_a?(Integer)

        nonempty_string(json, 'ruleset_version')
      end

      private_class_method :nonempty_string, :decision, :score, :matched_rule, :reasons, :ruleset_version
    end

    # Why there is no assessment. Every one of these means the payment proceeds
    # unchecked (fail open); the reason is for the record and for the operator.
    class UnavailableReason < T::Enum
      enums do
        # The deadline ran out: while connecting, sending, or waiting for the answer.
        Timeout = new('timeout')
        # The circuit breaker is open, so no request was sent at all.
        BreakerOpen = new('breaker_open')
        # RiskGate answered with something other than 200.
        HttpStatus = new('http_status')
        # A 200 whose body is not an assessment, or bytes that are not HTTP.
        Malformed = new('malformed')
        # Refused, reset, or closed before an answer.
        Connection = new('connection')
      end
    end

    # RiskGate gave no usable answer within the deadline.
    class Unavailable < T::Struct
      const :reason, UnavailableReason
      const :detail, String
      # Set for http_status.
      const :status, T.nilable(Integer), default: nil
    end

    Result = T.type_alias { T.any(Assessment, Unavailable) }
  end
end
