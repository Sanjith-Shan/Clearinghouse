# typed: true
# frozen_string_literal: true

require 'json'
require 'uri'

module Clearinghouse
  module Risk
    # Asks RiskGate about one confirm attempt and always comes back within the
    # deadline, with an Assessment or an Unavailable. It never raises for anything
    # RiskGate or the network can do: the caller fails open on Unavailable, and an
    # exception would turn a risk outage into a payments outage.
    #
    # One client per process, shared by every thread: the connection pool and the
    # circuit breaker only work if everyone sees the same ones.
    class Client
      extend T::Sig

      DEFAULT_URL = 'http://127.0.0.1:8080'
      DEFAULT_DEADLINE_MS = 50
      PATH = '/v1/assess'

      # Statuses that say RiskGate itself is in trouble and count against the
      # breaker. Any other non-200 (a 400 for a body it rejects, a 404 for a wrong
      # URL) is our mistake, not an outage: it still fails open, but opening the
      # breaker would not fix it and would hide it behind breaker_open.
      BREAKER_STATUSES = [408, 429].freeze

      sig { returns(Integer) }
      attr_reader :deadline_ms

      sig { returns(CircuitBreaker) }
      attr_reader :breaker

      sig { returns(Http::Pool) }
      attr_reader :pool

      sig do
        params(base_url: String, deadline_ms: Integer, breaker: T.nilable(CircuitBreaker), clock: Monotonic,
               max_idle: Integer, idle_timeout: Float).void
      end
      def initialize(base_url: ENV.fetch('RISKGATE_URL', DEFAULT_URL),
                     deadline_ms: Integer(ENV.fetch('RISKGATE_DEADLINE_MS', DEFAULT_DEADLINE_MS.to_s)),
                     breaker: nil, clock: Monotonic::Real.new, max_idle: 16, idle_timeout: 30.0)
        uri = URI.parse(base_url)
        # RiskGate runs beside Clearinghouse on a private network. TLS would add a
        # handshake per new connection inside a 50 ms budget and is left to the
        # network layer (a sidecar or a mesh), so the client refuses to pretend.
        raise ArgumentError, "RISKGATE_URL must be http://, got #{base_url}" unless uri.scheme == 'http' && uri.host
        raise ArgumentError, 'deadline_ms must be positive' unless deadline_ms.positive?

        @host = T.let(uri.host.to_s, String)
        @port = T.let(uri.port || 80, Integer)
        @path = T.let("#{uri.path.to_s.chomp('/')}#{PATH}", String)
        @deadline_ms = deadline_ms
        @clock = clock
        @breaker = T.let(breaker || CircuitBreaker.new(clock: clock), CircuitBreaker)
        @pool = T.let(Http::Pool.new(host: @host, port: @port, clock: clock, max_idle: max_idle,
                                     idle_timeout: idle_timeout), Http::Pool)
      end

      # `attempt` is the intent's confirm attempt. The same payment and attempt always
      # send the same Idempotency-Key, so a retry after a crash gets RiskGate's stored
      # answer back and does not count the payment twice in its velocity features.
      sig { params(request: AssessRequest, attempt: Integer).returns(Result) }
      def assess(request, attempt:)
        permit = @breaker.acquire
        unless permit
          return Unavailable.new(reason: UnavailableReason::BreakerOpen,
                                 detail: 'circuit breaker open; RiskGate not called')
        end

        result = T.let(nil, T.nilable(Result))
        begin
          result = call(request, attempt)
        ensure
          # Recorded even if something unexpected raised, so a half-open probe can
          # never be left outstanding forever.
          @breaker.record(permit, success: !result.nil? && healthy?(result))
        end
        result
      end

      sig { void }
      def close
        @pool.close_all
      end

      private

      sig { params(result: Result).returns(T::Boolean) }
      def healthy?(result)
        return true if result.is_a?(Assessment)

        status = result.status
        result.reason == UnavailableReason::HttpStatus && !status.nil? && status < 500 &&
          !BREAKER_STATUSES.include?(status)
      end

      sig { params(request: AssessRequest, attempt: Integer).returns(Result) }
      def call(request, attempt)
        deadline = Http::Deadline.new(@clock, @deadline_ms / 1000.0)
        body = JSON.generate(request.to_json_hash)
        response = exchange(body, request.idempotency_key(attempt), deadline)
        interpret(response)
      rescue Http::DeadlineExceeded => e
        Unavailable.new(reason: UnavailableReason::Timeout, detail: "#{e.message} (#{@deadline_ms} ms)")
      rescue Http::ConnectionFailed => e
        Unavailable.new(reason: UnavailableReason::Connection, detail: e.message)
      rescue Http::ProtocolError => e
        Unavailable.new(reason: UnavailableReason::Malformed, detail: e.message)
      end

      # One request on a pooled connection. If a reused connection turns out to have
      # been closed by RiskGate while idle (reset or EOF before a single response
      # byte), it is retried once on a fresh connection, inside the same deadline.
      # Resending is safe because the Idempotency-Key makes RiskGate treat a second
      # copy as a replay. Any other failure is final.
      sig { params(body: String, key: String, deadline: Http::Deadline).returns(Http::Response) }
      def exchange(body, key, deadline)
        connection, reused = @pool.checkout(deadline)
        exchange = Http::Exchange.new(connection.socket, deadline)
        begin
          response = exchange.run(request_bytes(body, key, deadline))
        rescue Http::ConnectionFailed
          connection.close
          raise unless reused && !exchange.received_any?

          return exchange(body, key, deadline)
        rescue StandardError
          connection.close
          raise
        end
        connection.uses += 1
        response.keep_alive ? @pool.checkin(connection) : connection.close
        response
      end

      # RiskGate-Deadline-Ms carries what is left of the budget when the request is
      # written, rounded down, so RiskGate can give up on work nobody will wait for.
      sig { params(body: String, key: String, deadline: Http::Deadline).returns(String) }
      def request_bytes(body, key, deadline)
        # Payment ids are ours, so a key that is not a plain header token is a bug.
        raise ArgumentError, "idempotency key #{key.inspect} is not a header token" unless key.match?(/\A[!-~]+\z/)

        remaining_ms = [(deadline.remaining * 1000).floor, 1].max
        "POST #{@path} HTTP/1.1\r\n" \
          "Host: #{@host}:#{@port}\r\n" \
          "Content-Type: application/json\r\n" \
          "Accept: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\n" \
          "Idempotency-Key: #{key}\r\n" \
          "RiskGate-Deadline-Ms: #{remaining_ms}\r\n" \
          "Connection: keep-alive\r\n\r\n#{body}"
      end

      sig { params(response: Http::Response).returns(Result) }
      def interpret(response)
        unless response.status == 200
          return Unavailable.new(reason: UnavailableReason::HttpStatus, status: response.status,
                                 detail: "RiskGate answered #{response.status}: #{response.body[0, 200]}")
        end

        replayed = response.headers['idempotent-replayed'].to_s.downcase == 'true'
        Assessment.from_json(JSON.parse(response.body), replayed: replayed)
      rescue JSON::ParserError, Assessment::Invalid => e
        Unavailable.new(reason: UnavailableReason::Malformed, detail: "unreadable assessment: #{e.message[0, 200]}")
      end
    end
  end
end
