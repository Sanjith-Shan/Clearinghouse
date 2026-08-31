# typed: true
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module Clearinghouse
  module Acquirer
    # HTTP client for the acquirer. Its job is to turn every way a call can end into
    # one of four outcomes, and above all to never report Unavailable (safe to treat
    # as "nothing happened") when the acquirer might have committed. See
    # docs/design/sim.md, "Unknown versus Unavailable".
    #
    # The line between the two is drawn by *phase*, not by exception class. Each call
    # opens its own connection. A failure while connecting means no byte of the
    # request left this process, so it is Unavailable. Any failure after the connect
    # succeeded, while writing or while waiting for the answer, is Unknown, whatever
    # the exception says, because from here there is no way to know how far the
    # request got.
    class Client
      extend T::Sig

      DEFAULT_URL = 'http://127.0.0.1:4600'

      # Raised by the connect phase. Anything raised there is, by construction,
      # before the request was sent; the list only exists so an unexpected error
      # (a bug) still propagates instead of being swallowed as an outage.
      CONNECT_ERRORS = T.let(
        [Net::OpenTimeout, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError].freeze,
        T::Array[T.class_of(Exception)]
      )

      # Raised while the request is written or the response read.
      EXCHANGE_ERRORS = T.let(
        [Net::ReadTimeout, Net::WriteTimeout, EOFError, IOError, SystemCallError, Net::HTTPBadResponse,
         OpenSSL::SSL::SSLError].freeze,
        T::Array[T.class_of(Exception)]
      )

      sig do
        params(clock: Clock, base_url: String, open_timeout: Numeric, read_timeout: Numeric,
               write_timeout: Numeric).void
      end
      def initialize(clock:, base_url: ENV.fetch('CLEARINGHOUSE_ACQUIRER_URL', DEFAULT_URL),
                     open_timeout: 1.0, read_timeout: 5.0, write_timeout: 5.0)
        @clock = clock
        @uri = T.let(URI.parse(base_url), URI::Generic)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @write_timeout = write_timeout
      end

      sig do
        params(payment_method: String, amount: Money, capture: T::Boolean, reference: String,
               idempotency_key: String).returns(Outcome)
      end
      def authorize(payment_method:, amount:, capture:, reference:, idempotency_key:)
        mutate('/authorize', idempotency_key,
               'payment_method' => payment_method, 'amount' => amount.amount, 'currency' => amount.currency,
               'capture' => capture, 'reference' => reference)
      end

      sig { params(acquirer_reference: String, amount: Money, idempotency_key: String).returns(Outcome) }
      def capture(acquirer_reference:, amount:, idempotency_key:)
        mutate('/capture', idempotency_key,
               'acquirer_reference' => acquirer_reference, 'amount' => amount.amount, 'currency' => amount.currency)
      end

      sig { params(acquirer_reference: String, idempotency_key: String).returns(Outcome) }
      def void(acquirer_reference:, idempotency_key:)
        mutate('/void', idempotency_key, 'acquirer_reference' => acquirer_reference)
      end

      sig { params(acquirer_reference: String, amount: Money, idempotency_key: String).returns(Outcome) }
      def refund(acquirer_reference:, amount:, idempotency_key:)
        mutate('/refund', idempotency_key,
               'acquirer_reference' => acquirer_reference, 'amount' => amount.amount, 'currency' => amount.currency)
      end

      # What the acquirer committed under a key, if anything. A GET has no side
      # effect, so every transport failure here is Unavailable: "no answer yet, ask
      # again". It never means "nothing happened"; only NotFound means that.
      sig { params(idempotency_key: String).returns(LookupOutcome) }
      def lookup(idempotency_key)
        request = Net::HTTP::Get.new(path("/operations/#{URI.encode_uri_component(idempotency_key)}"))
        response = exchange(request)
        case response
        when Unknown, Unavailable then return Unavailable.new(reason: response.reason)
        end
        # Only the simulator's own "no operation under this key" is NotFound. Any other
        # 404 (a wrong base URL, a proxy) says nothing about the payment and raises.
        return NotFound.new(idempotency_key: idempotency_key) if response.code == '404' && not_found_body?(response)
        return Unavailable.new(reason: "status #{response.code}") if response.code.start_with?('5')

        classify(response) || Unavailable.new(reason: 'unreadable response')
      end

      private

      sig { params(route: String, idempotency_key: String, body: T::Hash[String, T.untyped]).returns(Outcome) }
      def mutate(route, idempotency_key, body)
        request = Net::HTTP::Post.new(path(route))
        request['Idempotency-Key'] = idempotency_key
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(body)
        response = exchange(request)
        return response unless response.is_a?(Net::HTTPResponse)
        # 503 is the acquirer's "refused before doing anything". Any other 5xx could
        # come from a crash halfway through, so it proves nothing.
        return Unavailable.new(reason: 'acquirer answered 503') if response.code == '503'
        return Unknown.new(reason: "acquirer answered #{response.code}") if response.code.start_with?('5')

        classify(response) || Unknown.new(reason: "unreadable #{response.code} response")
      end

      # One request on its own connection. Returns the response, or the outcome the
      # transport failure implies given the phase it happened in.
      sig { params(request: Net::HTTPRequest).returns(T.any(Net::HTTPResponse, Unknown, Unavailable)) }
      def exchange(request)
        request['Sim-Time'] = @clock.now.utc.iso8601(6)
        request['Accept'] = 'application/json'
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == 'https'
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        T.unsafe(http).write_timeout = @write_timeout # missing from the stdlib RBI
        http.max_retries = 0 # a silent retry of a POST would hide the ambiguity this class exists to report
        begin
          http.start
        rescue *CONNECT_ERRORS => e
          return Unavailable.new(reason: "connect failed: #{e.class}: #{e.message}")
        end
        begin
          http.request(request)
        rescue *EXCHANGE_ERRORS => e
          Unknown.new(reason: "no response after sending: #{e.class}: #{e.message}")
        ensure
          http.finish if http.started?
        end
      end

      # 2xx with an operation becomes Approved or Declined; 4xx raises; nil means the
      # body could not be read as an operation.
      sig { params(response: Net::HTTPResponse).returns(T.nilable(T.any(Approved, Declined))) }
      def classify(response)
        body = parse(response.body)
        unless response.code.start_with?('2')
          raise ProtocolError.new(Integer(response.code), body&.fetch('error', nil)&.to_s,
                                  body&.fetch('message', nil).to_s)
        end
        return nil if body.nil?

        operation = Operation.from_json(body)
        return Approved.new(operation: operation) if operation.approved?

        Declined.new(code: operation.decline_code || operation.status, operation: operation)
      rescue KeyError, ArgumentError, TypeError
        nil
      end

      sig { params(response: Net::HTTPResponse).returns(T::Boolean) }
      def not_found_body?(response)
        parse(response.body)&.fetch('error', nil) == 'not_found'
      end

      sig { params(raw: T.nilable(String)).returns(T.nilable(T::Hash[String, T.untyped])) }
      def parse(raw)
        parsed = JSON.parse(raw.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      sig { params(route: String).returns(String) }
      def path(route)
        "#{@uri.path.to_s.chomp('/')}#{route}"
      end
    end
  end
end
