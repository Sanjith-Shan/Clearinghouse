# typed: true
# frozen_string_literal: true

require 'socket'

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): watching the acquirer calls.
  module CrashMatrix
    # A pass-through HTTP proxy between the API and the acquirer simulator that
    # writes down every request it forwards: method, path, Idempotency-Key and
    # what came back. The simulator's books say what it committed; only a
    # recording from outside both processes can show what the API *asked*, which
    # is how the harness tells "resumed by asking GET /operations/:key" apart from
    # "resumed by resending the authorization", two things that leave identical
    # books.
    #
    # One request per connection: Acquirer::Client opens a fresh connection per
    # call, and the proxy forces `Connection: close` upstream so the simulator ends
    # each exchange. A response the simulator drops (a Rack hijack that closes the
    # socket without writing) arrives here as EOF with no bytes, and the proxy
    # drops the downstream connection the same way, so the API sees exactly what
    # it would have seen talking to the simulator directly.
    #
    # An exchange is written down only after the last byte has been relayed, so
    # the API can have its answer, finish the request and reply to the harness
    # before the proxy's thread gets round to recording it. `mark` and `since`
    # therefore wait until nothing is in flight: every connection the proxy
    # accepted has been recorded (or has failed). Without that wait, a loaded
    # machine attributed an exchange to the next stage or to none (the flaky
    # `retry_1` expectation in spec/experiments/crash_matrix_run_spec.rb).
    class RecordingProxy
      extend T::Sig

      # One forwarded request.
      class Exchange < T::Struct
        const :seq, Integer
        const :http_method, String
        const :path, String
        const :idempotency_key, T.nilable(String)
        # The upstream status code, or nil when the simulator hung up without
        # answering.
        const :status, T.nilable(Integer)

        extend T::Sig

        sig { returns(String) }
        def to_s
          key = idempotency_key ? " [#{idempotency_key}]" : nil
          "#{http_method} #{path}#{key} -> #{status || 'dropped'}"
        end
      end

      sig { returns(Integer) }
      attr_reader :port

      sig { params(upstream_port: Integer).void }
      def initialize(upstream_port:)
        @upstream_port = upstream_port
        @server = T.let(TCPServer.new('127.0.0.1', 0), TCPServer)
        @port = T.let(@server.addr[1], Integer)
        @exchanges = T.let([], T::Array[Exchange])
        @mutex = T.let(Mutex.new, Thread::Mutex)
        @settled = T.let(ConditionVariable.new, Thread::ConditionVariable)
        @in_flight = T.let(0, Integer)
        @thread = T.let(nil, T.nilable(Thread))
      end

      sig { returns(String) }
      def url = "http://127.0.0.1:#{@port}"

      sig { returns(T.self_type) }
      def start
        @thread = Thread.new do
          loop do
            client = @server.accept
            # Counted here, before the request is even read: the API cannot have
            # an answer for a connection the proxy has not accepted yet.
            @mutex.synchronize { @in_flight += 1 }
            Thread.new(client) { |c| serve(c) }
          end
        rescue IOError, Errno::EBADF
          nil
        end
        self
      end

      sig { void }
      def stop
        @server.close
        @thread&.join(2)
      end

      # A position in the recording, so a stage can read only its own exchanges.
      # Waits for the exchanges in flight, so none of an earlier stage's lands
      # after the mark.
      sig { params(timeout: Float).returns(Integer) }
      def mark(timeout: SETTLE_TIMEOUT)
        @mutex.synchronize do
          settle(timeout)
          @exchanges.length
        end
      end

      # Everything recorded after `mark`, once nothing is in flight.
      sig { params(mark: Integer, timeout: Float).returns(T::Array[Exchange]) }
      def since(mark, timeout: SETTLE_TIMEOUT)
        @mutex.synchronize do
          settle(timeout)
          T.must(@exchanges[mark..]).dup
        end
      end

      # How long `mark` and `since` wait for exchanges in flight. A relay ends when
      # the simulator answers or hangs up, which it does within its own latency
      # settings; one still open after this is a harness bug, and says so.
      SETTLE_TIMEOUT = 30.0

      class StillInFlightError < StandardError; end

      private

      # Called holding @mutex.
      sig { params(timeout: Float).void }
      def settle(timeout)
        deadline = CrashMatrix.monotonic + timeout
        while @in_flight.positive?
          left = deadline - CrashMatrix.monotonic
          raise StillInFlightError, "#{@in_flight} acquirer exchanges still in flight after #{timeout}s" if left <= 0

          @settled.wait(@mutex, left)
        end
      end

      sig { params(client: TCPSocket).void }
      def serve(client)
        head, body = read_request(client)
        return if head.nil?

        request_line, *header_lines = head.split("\r\n")
        method, path = request_line.to_s.split(' ', 3)
        key_line = header_lines.find { |l| l.downcase.start_with?('idempotency-key:') }
        key = key_line.split(':', 2).last.to_s.strip if key_line
        forwarded = [request_line, *header_lines.reject { |l| l.downcase.start_with?('connection:') },
                     'Connection: close'].join("\r\n")
        status = relay(client, "#{forwarded}\r\n\r\n#{body}")
        record(method.to_s, path.to_s, key, status)
      rescue IOError, SystemCallError
        nil
      ensure
        client.close unless client.closed?
        @mutex.synchronize do
          @in_flight -= 1
          @settled.broadcast
        end
      end

      # The request head and body, read by Content-Length. nil if the client went
      # away first.
      sig { params(client: TCPSocket).returns([T.nilable(String), String]) }
      def read_request(client)
        buffer = +''
        split = T.let(buffer.index("\r\n\r\n"), T.nilable(Integer))
        while split.nil?
          buffer << client.readpartial(16_384)
          split = buffer.index("\r\n\r\n")
        end
        head = T.must(buffer[0, split])
        rest = T.must(buffer[(split + 4)..])
        length = head[/^content-length:\s*(\d+)/i, 1].to_i
        rest << client.readpartial(16_384) while rest.bytesize < length
        [head, rest]
      rescue EOFError
        [nil, '']
      end

      # Sends the request upstream and copies the answer back byte for byte. The
      # status, or nil if the upstream closed without a byte.
      sig { params(client: TCPSocket, request: String).returns(T.nilable(Integer)) }
      def relay(client, request)
        upstream = TCPSocket.new('127.0.0.1', @upstream_port)
        upstream.write(request)
        first = +''
        begin
          loop do
            chunk = upstream.readpartial(16_384)
            first << chunk if first.bytesize < 64
            client.write(chunk)
          end
        rescue EOFError
          nil
        end
        first.empty? ? nil : first[%r{\AHTTP/1\.\d (\d{3})}, 1]&.to_i
      ensure
        upstream&.close
      end

      sig { params(method: String, path: String, key: T.nilable(String), status: T.nilable(Integer)).void }
      def record(method, path, key, status)
        @mutex.synchronize do
          @exchanges << Exchange.new(seq: @exchanges.length, http_method: method, path: path, idempotency_key: key,
                                     status: status)
        end
      end
    end
  end
end
