# typed: strict
# frozen_string_literal: true

require 'digest'
require 'json'

module Clearinghouse
  module Idempotency
    # The fingerprint of a request: SHA-256 (hex) of the canonical JSON of
    # [method, path, params]. A key reused with a different fingerprint is a 400
    # idempotency_error.
    #
    # What is in it, and why:
    #
    # - method, uppercased. POST /confirm and POST /cancel on the same path prefix
    #   are different requests.
    # - path, as routed, without the query string. It carries the object id
    #   (`/v1/payment_intents/pi_.../confirm`), so the same key sent to confirm a
    #   different intent is refused.
    # - params: everything the endpoint reads, which is the query string and the
    #   body merged, exactly what `api_params.raw` holds. `expand[]` is included,
    #   because it changes the response that will be stored and replayed.
    #
    # What is not, and why:
    #
    # - Headers. The merchant is already the key's scope. Clearinghouse-Version is
    #   deliberately left out: a retry that sends a different version is still the
    #   same payment, and it gets the stored response at the version first used,
    #   byte for byte, as Stripe does.
    #
    # Canonical form: object keys sorted by codepoint at every depth, arrays in
    # order, no whitespace, and every scalar except null written as a string (a
    # JSON float as Ruby prints it, which only free-form fields can carry). The
    # last rule makes a form-encoded body (`amount=2000`, where everything is a
    # string) and the same request as JSON (`{"amount":2000}`) fingerprint the
    # same, since the endpoint parses both to the same value.
    module Fingerprint
      extend T::Sig

      sig { params(method: String, path: String, params: T::Hash[String, T.untyped]).returns(String) }
      def self.compute(method:, path:, params:)
        Digest::SHA256.hexdigest(canonical_json([method.upcase, path, params]))
      end

      sig { params(value: T.untyped).returns(String) }
      def self.canonical_json(value)
        JSON.generate(canonical(value))
      end

      sig { params(value: T.untyped).returns(T.untyped) }
      def self.canonical(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, canonical(v)] }.sort.to_h
        when Array then value.map { |v| canonical(v) }
        when nil then nil
        when String then value
        when Numeric, TrueClass, FalseClass, Symbol then value.to_s
        else raise ArgumentError, "cannot fingerprint a #{value.class}"
        end
      end
    end
  end
end
