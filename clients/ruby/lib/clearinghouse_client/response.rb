# typed: true
# frozen_string_literal: true

module ClearinghouseClient
  # One HTTP response. Header names are lowercased.
  class Response
    extend T::Sig

    sig { returns(Integer) }
    attr_reader :status

    sig { returns(T::Hash[String, String]) }
    attr_reader :headers

    sig { returns(String) }
    attr_reader :body

    # How many HTTP attempts the logical call took, retries included.
    sig { returns(Integer) }
    attr_reader :attempts

    sig { params(status: Integer, headers: T::Hash[String, String], body: String, attempts: Integer).void }
    def initialize(status:, headers:, body:, attempts: 1)
      @status = status
      @headers = headers
      @body = body
      @attempts = attempts
    end

    sig { params(attempts: Integer).returns(Response) }
    def with_attempts(attempts)
      Response.new(status: status, headers: headers, body: body, attempts: attempts)
    end

    sig { returns(T::Boolean) }
    def success?
      status >= 200 && status < 300
    end

    # The parsed JSON body. Raises APIError if a success response is not a JSON object.
    sig { returns(T::Hash[String, T.untyped]) }
    def data
      parsed = parsed_body
      return parsed if parsed.is_a?(Hash)

      raise APIError.new("Expected a JSON object in the response (HTTP #{status})", http_status: status,
                                                                                    request_id: request_id)
    end

    # The body's `error` object, or {} when there is none.
    sig { returns(T::Hash[String, T.untyped]) }
    def error_object
      parsed = parsed_body
      inner = parsed.is_a?(Hash) ? parsed['error'] : nil
      inner.is_a?(Hash) ? inner : {}
    end

    sig { returns(T.nilable(String)) }
    def request_id
      headers['request-id']
    end

    # True when the server answered from a stored result for this Idempotency-Key
    # instead of running the request again.
    sig { returns(T::Boolean) }
    def idempotent_replayed?
      headers['idempotent-replayed'] == 'true'
    end

    # The server's Clearinghouse-Should-Retry verdict, or nil when it gave none.
    sig { returns(T.nilable(T::Boolean)) }
    def should_retry
      case headers['clearinghouse-should-retry']
      when 'true' then true
      when 'false' then false
      end
    end

    # Retry-After in seconds, when it is a plain non-negative integer. The HTTP-date
    # form is ignored: the server never sends it, and parsing a date from a clock we
    # do not share buys nothing.
    sig { returns(T.nilable(Integer)) }
    def retry_after
      value = headers['retry-after']
      Integer(value, 10) if value&.match?(/\A[0-9]{1,9}\z/)
    end

    private

    sig { returns(T.untyped) }
    def parsed_body
      return @parsed_body if defined?(@parsed_body)

      @parsed_body = begin
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
