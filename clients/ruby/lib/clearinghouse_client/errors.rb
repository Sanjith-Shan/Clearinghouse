# typed: true
# frozen_string_literal: true

module ClearinghouseClient
  # Base class for everything the library raises. `error` is the raw `error` object
  # from the response body (`type`, `code`, `decline_code`, `param`, `message`), or an
  # empty hash when there was no parseable body.
  class Error < StandardError
    extend T::Sig

    sig { returns(T.nilable(Integer)) }
    attr_reader :http_status

    sig { returns(T.nilable(String)) }
    attr_reader :request_id

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :error

    sig { returns(T::Hash[String, String]) }
    attr_reader :http_headers

    sig do
      params(message: String, http_status: T.nilable(Integer), request_id: T.nilable(String),
             error: T::Hash[String, T.untyped], http_headers: T::Hash[String, String]).void
    end
    def initialize(message, http_status: nil, request_id: nil, error: {}, http_headers: {})
      super(message)
      @http_status = http_status
      @request_id = request_id
      @error = error
      @http_headers = http_headers
    end

    sig { returns(T.nilable(String)) }
    def code
      error['code']
    end

    sig { returns(String) }
    def to_s
      parts = [http_status && "(Status #{http_status})", request_id && "(Request #{request_id})", super]
      parts.compact.join(' ')
    end
  end

  # The card was declined. `decline_code` is the issuer's reason.
  class CardError < Error
    sig { returns(T.nilable(String)) }
    def decline_code
      error['decline_code']
    end
  end

  # A bad parameter, a missing object, or an action the object's state does not allow.
  class InvalidRequestError < Error
    sig { returns(T.nilable(String)) }
    def param
      error['param']
    end
  end

  # An Idempotency-Key reused with different parameters (400), or still in use by a
  # request that has not finished (409, which the client retries on its own).
  class IdempotencyError < Error; end

  # Missing or wrong API key.
  class AuthenticationError < Error; end

  # Too many requests. Retried automatically; raised once retries run out.
  class RateLimitError < Error; end

  # Clearinghouse's risk rules blocked the payment. Not a decline by the bank.
  class RiskError < Error; end

  # Something went wrong on the server, or the response could not be understood.
  class APIError < Error; end

  # No HTTP response arrived: the connection failed, dropped or timed out.
  #
  # `maybe_processed?` says whether the request might have reached the server. False
  # means the connection never opened, so nothing was sent. True means it opened and
  # then failed, and the server may have done the work. Either way a retry with the
  # same Idempotency-Key is safe; the flag is for humans reading logs.
  class APIConnectionError < Error
    sig { params(message: String, maybe_processed: T::Boolean).void }
    def initialize(message, maybe_processed:)
      super(message)
      @maybe_processed = maybe_processed
    end

    sig { returns(T::Boolean) }
    def maybe_processed?
      @maybe_processed
    end
  end

  # Maps an error response to its exception class.
  module Errors
    extend T::Sig

    BY_TYPE = {
      'card_error' => CardError,
      'invalid_request_error' => InvalidRequestError,
      'idempotency_error' => IdempotencyError,
      'authentication_error' => AuthenticationError,
      'rate_limit_error' => RateLimitError,
      'risk_error' => RiskError,
      'api_error' => APIError
    }.freeze

    # For bodies without a known `type` (a proxy's HTML 502, say), fall back on the
    # status code.
    BY_STATUS = {
      400 => InvalidRequestError, 401 => AuthenticationError, 402 => CardError, 404 => InvalidRequestError,
      409 => IdempotencyError, 429 => RateLimitError
    }.freeze

    sig { params(response: Response).returns(Error) }
    def self.from_response(response)
      error = response.error_object
      klass = BY_TYPE[error['type']] || BY_STATUS.fetch(response.status, APIError)
      message = error['message'].is_a?(String) ? error['message'] : "Unexpected HTTP #{response.status} response"
      klass.new(message, http_status: response.status, request_id: response.request_id, error: error,
                         http_headers: response.headers)
    end
  end
end
