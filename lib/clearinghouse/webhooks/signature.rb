# typed: strict
# frozen_string_literal: true

require 'openssl'

module Clearinghouse
  module Webhooks
    # Signs and verifies the Clearinghouse-Signature header:
    #
    #   Clearinghouse-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>[,v1=...]
    #
    # The scheme follows Stripe's documented webhook signatures. The timestamp is inside
    # the MAC, so a replayed delivery cannot be re-dated without the secret, and the
    # verifier's tolerance bounds how long a captured delivery stays usable. During a
    # secret rotation the header carries one v1 per active secret.
    #
    # The parsing rules here are the contract for every verifier, and the Go verifier in
    # clients/go/webhooksig implements the same ones. spec/fixtures/signatures.json pins
    # them down; docs/design/webhook-security.md explains each decision.
    module Signature
      extend T::Sig

      HEADER = 'Clearinghouse-Signature'
      SCHEME = 'v1'
      DEFAULT_TOLERANCE = 300

      # 15 digits reaches the year 31 million, and keeps every verifier inside int64
      # without having to think about overflow.
      TIMESTAMP_FORMAT = /\A[0-9]{1,15}\z/
      # Only spaces and tabs around an element are optional whitespace. String#strip
      # would also eat NUL and newlines, which have no business in a header.
      OPTIONAL_WHITESPACE = /\A[ \t]+|[ \t]+\z/

      # The error codes, spelled exactly as the shared vectors spell them.
      class ErrorCode < T::Enum
        enums do
          NoMatchingSignature = new('no_matching_signature')
          TimestampOutsideTolerance = new('timestamp_outside_tolerance')
          MalformedHeader = new('malformed_header')
        end
      end

      # The outcome of a verification. `timestamp` is set whenever the header parsed.
      class Result < T::Struct
        extend T::Sig

        const :error, T.nilable(ErrorCode)
        const :timestamp, T.nilable(Integer)

        sig { returns(T::Boolean) }
        def valid?
          error.nil?
        end
      end

      # Raised by verify! so a caller can let it propagate to a 400.
      class VerificationError < Clearinghouse::Error
        extend T::Sig

        sig { returns(ErrorCode) }
        attr_reader :code

        sig { params(code: ErrorCode).void }
        def initialize(code)
          @code = code
          super(code.serialize)
        end
      end

      # What the header said, once it parsed.
      class Parsed < T::Struct
        const :timestamp, Integer
        const :timestamp_text, String
        const :signatures, T::Array[String]
      end

      sig { params(payload: String, secrets: T::Array[String], timestamp: Integer).returns(String) }
      def self.sign(payload:, secrets:, timestamp:)
        check_secrets!(secrets)
        raise ArgumentError, "timestamp must be non-negative, got #{timestamp}" if timestamp.negative?

        t = timestamp.to_s
        (["t=#{t}"] + secrets.map { |secret| "#{SCHEME}=#{compute(secret, t, payload)}" }).join(',')
      end

      # Checks the signature first and the timestamp second, the same order Stripe's
      # libraries use, so a forged header with a stale timestamp reports the forgery.
      sig do
        params(payload: String, header: String, secrets: T::Array[String], now: Integer, tolerance: Integer)
          .returns(Result)
      end
      def self.verify(payload:, header:, secrets:, now:, tolerance: DEFAULT_TOLERANCE)
        check_secrets!(secrets)
        # Zero is a legal, if harsh, tolerance here: it means "exactly now". Unlike
        # Stripe's libraries it never means "skip the check".
        raise ArgumentError, "tolerance must be non-negative, got #{tolerance}" if tolerance.negative?

        parsed = parse(header)
        return Result.new(error: ErrorCode::MalformedHeader) if parsed.nil?

        unless matches_any?(parsed, payload, secrets)
          return Result.new(error: ErrorCode::NoMatchingSignature, timestamp: parsed.timestamp)
        end

        # Inclusive boundary: a delivery exactly `tolerance` seconds old (or ahead) passes.
        if (now - parsed.timestamp).abs > tolerance
          return Result.new(error: ErrorCode::TimestampOutsideTolerance, timestamp: parsed.timestamp)
        end

        Result.new(error: nil, timestamp: parsed.timestamp)
      end

      sig do
        params(payload: String, header: String, secrets: T::Array[String], now: Integer, tolerance: Integer)
          .returns(Integer)
      end
      def self.verify!(payload:, header:, secrets:, now:, tolerance: DEFAULT_TOLERANCE)
        result = verify(payload: payload, header: header, secrets: secrets, now: now, tolerance: tolerance)
        error = result.error
        raise VerificationError, error if error

        T.must(result.timestamp)
      end

      # Parses a header into its timestamp and v1 signatures, or nil if it is malformed.
      #
      # Grammar: element *( "," element ), element = OWS key "=" value OWS, where OWS is
      # spaces and tabs. Exactly one `t`, made of 1 to 15 ASCII digits. At least one
      # non-empty `v1`. Keys other than t and v1 (v0, v2, anything) are ignored, which
      # is how Stripe tells verifiers to treat schemes they do not know. An empty element
      # (",," or a trailing comma) or an element without a key is malformed.
      sig { params(header: String).returns(T.nilable(Parsed)) }
      def self.parse(header)
        timestamp_text = T.let(nil, T.nilable(String))
        signatures = T.let([], T::Array[String])

        # split with -1 keeps trailing empty elements so "t=1,v1=x," is caught.
        header.b.split(',', -1).each do |raw|
          key, value = raw.gsub(OPTIONAL_WHITESPACE, '').split('=', 2)
          return nil if key.nil? || key.empty? || value.nil?

          case key
          when 't'
            return nil if timestamp_text || !TIMESTAMP_FORMAT.match?(value)

            timestamp_text = value
          when SCHEME
            return nil if value.empty?

            signatures << value
          end
        end
        return nil if timestamp_text.nil? || signatures.empty?

        Parsed.new(timestamp: Integer(timestamp_text, 10), timestamp_text: timestamp_text, signatures: signatures)
      end

      # Lowercase hex, as sent. The signed string uses the timestamp text exactly as it
      # appeared in the header, so a verifier never re-formats it.
      sig { params(secret: String, timestamp_text: String, payload: String).returns(String) }
      def self.compute(secret, timestamp_text, payload)
        OpenSSL::HMAC.hexdigest('SHA256', secret.b, "#{timestamp_text}.".b + payload.b)
      end

      # Every candidate is compared against every secret. The comparison is constant
      # time for equal lengths; a length mismatch returns early, which only reveals that
      # the candidate is not 64 characters long, something the attacker already knows.
      # Uppercase hex does not match: signatures are compared as the lowercase strings
      # the signer emits, as Stripe's libraries do.
      sig { params(parsed: Parsed, payload: String, secrets: T::Array[String]).returns(T::Boolean) }
      def self.matches_any?(parsed, payload, secrets)
        expected = secrets.map { |secret| compute(secret, parsed.timestamp_text, payload) }
        parsed.signatures.any? do |candidate|
          expected.any? { |want| secure_equal?(want, candidate) }
        end
      end

      sig { params(left: String, right: String).returns(T::Boolean) }
      def self.secure_equal?(left, right)
        return false unless left.bytesize == right.bytesize

        OpenSSL.fixed_length_secure_compare(left, right)
      end

      sig { params(secrets: T::Array[String]).void }
      def self.check_secrets!(secrets)
        raise ArgumentError, 'at least one secret is required' if secrets.empty?
        raise ArgumentError, 'secrets must not be empty strings' if secrets.any?(&:empty?)
      end

      private_class_method :matches_any?, :secure_equal?, :check_secrets!
    end
  end
end
