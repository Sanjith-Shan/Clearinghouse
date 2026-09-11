# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    # The typed errors the API returns, each rendered as
    #
    #   {"error": {"type", "code", "decline_code", "param", "message", "doc_url"}}
    #
    # with its own HTTP status. `type` says which class of problem it is and what the
    # caller can do about it, `code` is the machine-readable reason, and `param` names
    # the request parameter at fault. `doc_url` is present only when there is a code.
    #
    # Each class also knows whether retrying the exact same request (same parameters,
    # same Idempotency-Key) could ever succeed. That becomes the
    # `Clearinghouse-Should-Retry` header; see docs/design/api.md for the rule.
    module Errors
      extend T::Sig

      DOC_BASE = 'https://github.com/Sanjith-Shan/Clearinghouse/blob/main/docs/api-errors.md'

      # What the Clearinghouse-Should-Retry header says about sending the same
      # request again. Unknown means the header is left out.
      class RetryHint < T::Enum
        enums do
          Retry = new('true')
          DoNotRetry = new('false')
          Unknown = new(nil)
        end
      end

      # Base class. Not raised directly.
      class Base < Clearinghouse::Error
        extend T::Sig

        sig { returns(T.nilable(String)) }
        attr_reader :code, :decline_code, :param

        sig do
          params(message: String, code: T.nilable(String), decline_code: T.nilable(String),
                 param: T.nilable(String)).void
        end
        def initialize(message, code: nil, decline_code: nil, param: nil)
          super(message)
          @code = code
          @decline_code = decline_code
          @param = param
        end

        sig { returns(String) }
        def type
          raise NotImplementedError
        end

        sig { returns(Integer) }
        def http_status
          raise NotImplementedError
        end

        # Whether a retry of the same request can succeed, or Unknown when that
        # depends on something the error cannot see. Most errors are deterministic
        # in their inputs, so the default is DoNotRetry.
        sig { returns(RetryHint) }
        def retry_hint
          RetryHint::DoNotRetry
        end

        sig { returns(T::Hash[String, T.untyped]) }
        def to_h
          body = { 'type' => type, 'code' => code, 'decline_code' => decline_code, 'param' => param,
                   'message' => message }
          body['doc_url'] = "#{DOC_BASE}##{code}" if code
          { 'error' => body }
        end
      end

      # The request was malformed: a missing, unknown or invalid parameter, or an
      # action the object's state does not allow.
      class InvalidRequestError < Base
        sig { override.returns(String) }
        def type = 'invalid_request_error'

        sig { override.returns(Integer) }
        def http_status = 400

        sig { params(name: String).returns(InvalidRequestError) }
        def self.unknown_parameter(name)
          new("Received unknown parameter: #{name}", code: 'parameter_unknown', param: name)
        end

        sig { params(name: String).returns(InvalidRequestError) }
        def self.missing_parameter(name)
          new("Missing required param: #{name}.", code: 'parameter_missing', param: name)
        end

        sig { params(name: String, detail: String).returns(InvalidRequestError) }
        def self.invalid_parameter(name, detail)
          new("Invalid #{name}: #{detail}", code: 'parameter_invalid', param: name)
        end
      end

      # A resource or route that does not exist. Same type as a bad parameter, as in
      # Stripe's API, but a 404.
      class NotFoundError < InvalidRequestError
        sig { override.returns(Integer) }
        def http_status = 404

        sig { params(kind: String, id: String, param: String).returns(NotFoundError) }
        def self.resource(kind, id, param: 'id')
          new("No such #{kind}: '#{id}'", code: 'resource_missing', param: param)
        end

        sig { params(method: String, path: String).returns(NotFoundError) }
        def self.route(method, path)
          new("Unrecognized request URL (#{method}: #{path}).", code: 'url_invalid')
        end
      end

      # The card was declined. `decline_code` carries the issuer's reason.
      class CardError < Base
        sig { override.returns(String) }
        def type = 'card_error'

        sig { override.returns(Integer) }
        def http_status = 402
      end

      # An Idempotency-Key was reused in a way that cannot be honoured.
      class IdempotencyError < Base
        sig { override.returns(String) }
        def type = 'idempotency_error'

        sig { override.returns(Integer) }
        def http_status = 400
      end

      # Same key, different parameters. Retrying the same thing will fail the same way.
      class IdempotencyKeyReusedError < IdempotencyError
        sig { params(key: String).void }
        def initialize(key)
          super('Keys for idempotent requests can only be used with the same parameters they were first ' \
                "used with. Try using a key other than '#{key}' if you meant to execute a different request.",
                code: 'idempotency_key_reused')
        end
      end

      # Same key while the first request is still running. Retrying later is exactly
      # right: it will either replay the stored result or resume the work.
      class IdempotencyKeyInUseError < IdempotencyError
        sig { params(key: String).void }
        def initialize(key)
          super("There is currently another in-progress request using this Idempotency-Key ('#{key}'). " \
                'Retry after it completes.', code: 'idempotency_key_in_use')
        end

        sig { override.returns(Integer) }
        def http_status = 409

        sig { override.returns(RetryHint) }
        def retry_hint = RetryHint::Retry
      end

      # No API key, or one that matches no merchant.
      class AuthenticationError < Base
        sig { override.returns(String) }
        def type = 'authentication_error'

        sig { override.returns(Integer) }
        def http_status = 401
      end

      # The object is owned by another request that is still running (a capture
      # while a cancel of the same intent is between its phases). Stripe's code for
      # this is lock_timeout. Transient, so it is never stored as a key's response.
      class LockTimeoutError < InvalidRequestError
        sig { params(message: String).void }
        def initialize(message)
          super(message, code: 'lock_timeout')
        end

        sig { override.returns(Integer) }
        def http_status = 409

        sig { override.returns(RetryHint) }
        def retry_hint = RetryHint::Retry
      end

      # Nothing raises this yet (the spec leaves rate limiting out of scope), but the
      # type exists so clients and the SDK handle it from day one.
      class RateLimitError < Base
        sig { params(message: String).void }
        def initialize(message = 'Too many requests hit the API too quickly.')
          super(message, code: 'rate_limit')
        end

        sig { override.returns(String) }
        def type = 'rate_limit_error'

        sig { override.returns(Integer) }
        def http_status = 429

        sig { override.returns(RetryHint) }
        def retry_hint = RetryHint::Retry
      end

      # RiskGate returned `block`. A 402 like a decline, but its own type so a client
      # can tell "the bank said no" from "we said no".
      class RiskError < Base
        sig { params(message: String).void }
        def initialize(message = 'This payment was blocked by risk rules.')
          super(message, code: 'payment_blocked')
        end

        sig { override.returns(String) }
        def type = 'risk_error'

        sig { override.returns(Integer) }
        def http_status = 402
      end

      # Something broke on our side. The message never carries the exception's text,
      # only the request id to quote to support.
      class ApiError < Base
        sig { params(request_id: String).void }
        def initialize(request_id)
          super("An unexpected error occurred while processing your request (#{request_id}).")
        end

        sig { override.returns(String) }
        def type = 'api_error'

        sig { override.returns(Integer) }
        def http_status = 500

        # Depends on the request: see Errors.retry_hint_for.
        sig { override.returns(RetryHint) }
        def retry_hint = RetryHint::Unknown
      end

      # The acquirer did not answer, so we do not know yet whether the card was
      # charged (or it answered that it could not take the request). Nothing has
      # failed: the payment stays where it was and resumes on retry. A 503, not a
      # 500, because it is not our bug. Retrying is safe exactly when a 500 would
      # be (see Errors.retry_header): with an Idempotency-Key the retry resumes the
      # same attempt instead of starting another.
      class AcquirerUnavailableError < Base
        sig { params(detail: String).void }
        def initialize(detail = 'The card network did not answer in time.')
          super("#{detail} The payment has not failed; retry the request with the same Idempotency-Key.",
                code: 'acquirer_unavailable')
        end

        sig { override.returns(String) }
        def type = 'api_error'

        sig { override.returns(Integer) }
        def http_status = 503

        sig { override.returns(RetryHint) }
        def retry_hint = RetryHint::Unknown
      end

      SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

      # The Clearinghouse-Should-Retry value for an error, or nil to omit the header.
      # A 500 may have happened after a side effect committed. Retrying is still
      # safe when the request is read-only, or when it carried an Idempotency-Key,
      # because the retry then replays or resumes instead of repeating. A keyless
      # POST gets no header: we do not know whether the first attempt did anything.
      sig { params(error: Base, method: String, idempotency_key: T.nilable(String)).returns(T.nilable(String)) }
      def self.retry_header(error, method:, idempotency_key:)
        hint = error.retry_hint
        hint = RetryHint::Retry if hint == RetryHint::Unknown && (SAFE_METHODS.include?(method) || idempotency_key)
        hint.serialize
      end
    end
  end
end
