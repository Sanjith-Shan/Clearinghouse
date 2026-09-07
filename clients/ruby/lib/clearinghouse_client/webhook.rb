# typed: true
# frozen_string_literal: true

module ClearinghouseClient
  # The Clearinghouse-Signature header did not verify. `code` is one of
  # `no_matching_signature`, `timestamp_outside_tolerance` or `malformed_header`,
  # spelled as in the shared test vectors.
  class SignatureVerificationError < Error
    sig { returns(String) }
    attr_reader :code

    sig { params(code: String, header: String).void }
    def initialize(code, header)
      super("Webhook signature verification failed: #{code}")
      @code = code
      @header = header
    end

    sig { returns(String) }
    attr_reader :header
  end

  # The signature verified but the payload is not a JSON object.
  class InvalidPayloadError < Error; end

  # Verifying webhook deliveries.
  #
  #   event = ClearinghouseClient::Webhook.construct_event(
  #     request.body.read, request.env['HTTP_CLEARINGHOUSE_SIGNATURE'], ENV.fetch('WEBHOOK_SECRET')
  #   )
  #
  # Pass the raw body exactly as received. Parsing and re-serialising it changes the
  # bytes and the signature no longer matches.
  module Webhook
    extend T::Sig

    DEFAULT_TOLERANCE = 300

    # Verifies the header and returns the parsed event. `secret` may be an Array of
    # secrets during a rotation; any of them verifying is enough. `now` (unix seconds)
    # defaults to the wall clock.
    sig do
      params(payload: String, header: String, secret: T.any(String, T::Array[String]), tolerance: Integer,
             now: T.nilable(Integer)).returns(T::Hash[String, T.untyped])
    end
    def self.construct_event(payload, header, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
      Signature.verify_header(payload, header, Array(secret), tolerance: tolerance, now: now || Time.now.to_i)
      event = begin
        JSON.parse(payload)
      rescue JSON::ParserError => e
        raise InvalidPayloadError, "Webhook payload is not valid JSON: #{e.message}"
      end
      raise InvalidPayloadError, 'Webhook payload is not a JSON object' unless event.is_a?(Hash)

      event
    end

    # A copy of the server's rules in lib/clearinghouse/webhooks/signature.rb, because a
    # client library cannot depend on server code. spec/fixtures/signatures.json pins
    # both down, and a differential spec compares the two on generated headers.
    #
    # Header grammar: element *("," element), element = OWS key "=" value OWS, OWS being
    # spaces and tabs. Exactly one `t` of 1 to 15 ASCII digits, at least one non-empty
    # `v1`, other keys ignored, empty elements malformed. The signature is checked
    # before the timestamp, so a forgery with a stale timestamp reports the forgery.
    module Signature
      extend T::Sig

      TIMESTAMP_FORMAT = /\A[0-9]{1,15}\z/
      OPTIONAL_WHITESPACE = /\A[ \t]+|[ \t]+\z/

      # Returns the header's timestamp (unix seconds) or raises SignatureVerificationError.
      sig do
        params(payload: String, header: String, secrets: T::Array[String], tolerance: Integer,
               now: Integer).returns(Integer)
      end
      def self.verify_header(payload, header, secrets, tolerance:, now:)
        raise ArgumentError, 'at least one non-empty secret is required' if secrets.empty? || secrets.any?(&:empty?)
        raise ArgumentError, "tolerance must be non-negative, got #{tolerance}" if tolerance.negative?

        timestamp_text, signatures = parse(header)
        raise SignatureVerificationError.new('malformed_header', header) if timestamp_text.nil?

        expected = secrets.map { |secret| compute(secret, timestamp_text, payload) }
        unless signatures.any? { |candidate| expected.any? { |want| secure_equal?(want, candidate) } }
          raise SignatureVerificationError.new('no_matching_signature', header)
        end

        timestamp = Integer(timestamp_text, 10)
        # Inclusive: a delivery exactly `tolerance` seconds old (or ahead) passes.
        raise SignatureVerificationError.new('timestamp_outside_tolerance', header) if (now - timestamp).abs > tolerance

        timestamp
      end

      # The timestamp text and v1 signatures, or [nil, []] if the header is malformed.
      sig { params(header: String).returns([T.nilable(String), T::Array[String]]) }
      def self.parse(header)
        timestamps = []
        signatures = []
        # -1 keeps trailing empty elements, so "t=1,v1=x," is caught.
        header.b.split(',', -1).each do |raw|
          key, value = raw.gsub(OPTIONAL_WHITESPACE, '').split('=', 2)
          return [nil, []] if key.nil? || key.empty? || value.nil?

          timestamps << value if key == 't'
          signatures << value if key == 'v1'
        end
        timestamp = timestamps.first
        return [nil, []] unless timestamps.length == 1 && TIMESTAMP_FORMAT.match?(timestamp)
        return [nil, []] if signatures.empty? || signatures.any?(&:empty?)

        [timestamp, signatures]
      end

      # Signed over the timestamp exactly as it appeared in the header.
      sig { params(secret: String, timestamp_text: String, payload: String).returns(String) }
      def self.compute(secret, timestamp_text, payload)
        OpenSSL::HMAC.hexdigest('SHA256', secret.b, "#{timestamp_text}.".b + payload.b)
      end

      # Constant time for equal lengths. A length mismatch returns early, which only
      # reveals that the candidate is not 64 characters, something the sender knows.
      sig { params(left: String, right: String).returns(T::Boolean) }
      def self.secure_equal?(left, right)
        return false unless left.bytesize == right.bytesize

        OpenSSL.fixed_length_secure_compare(left, right)
      end

      private_class_method :compute, :secure_equal?
    end
  end
end
