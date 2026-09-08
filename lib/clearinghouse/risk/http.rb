# typed: true
# frozen_string_literal: true

require 'socket'
require 'uri'

module Clearinghouse
  module Risk
    # A small HTTP/1.1 client with one deadline over the whole exchange and a pool of
    # keep-alive connections.
    #
    # Net::HTTP was the obvious choice and does not do this. Its open, write and read
    # timeouts are per phase and, for reads, per socket read: a server that sends one
    # byte every 40 ms keeps a 50 ms read_timeout happy forever. Wrapping it in
    # Timeout.timeout does bound it, but by raising into the thread from another one,
    # at any point, including inside the pool's bookkeeping. Here every socket
    # operation is non-blocking and every wait is IO#wait_* with whatever is left of
    # the one deadline, so connect + write + read can never together exceed it.
    #
    # The pool matters because a TCP handshake to a local service is a real share of a
    # 50 ms budget at p99, and paying it on every confirm is waste.
    module Http
      extend T::Sig

      class Error < StandardError; end
      # The deadline ran out. No response was read, or only part of one.
      class DeadlineExceeded < Error; end
      # Refused, reset, closed early, or unreachable.
      class ConnectionFailed < Error; end
      # Bytes arrived that are not an HTTP/1.1 response we can read.
      class ProtocolError < Error; end

      # A parsed response.
      class Response < T::Struct
        const :status, Integer
        const :headers, T::Hash[String, String]
        const :body, String
        const :keep_alive, T::Boolean
      end

      # A time limit on the monotonic clock.
      class Deadline
        extend T::Sig

        sig { params(clock: Monotonic, seconds: Float).void }
        def initialize(clock, seconds)
          @clock = clock
          @at = T.let(clock.now + seconds, Float)
        end

        # Seconds left; raises once there are none.
        sig { returns(Float) }
        def remaining!
          left = @at - @clock.now
          raise DeadlineExceeded, 'deadline exceeded' unless left.positive?

          left
        end

        sig { returns(Float) }
        def remaining
          [@at - @clock.now, 0.0].max
        end
      end

      # One socket and when it was last returned to the pool.
      class Connection
        extend T::Sig

        sig { returns(Socket) }
        attr_reader :socket

        sig { returns(Float) }
        attr_accessor :idle_since

        sig { returns(Integer) }
        attr_accessor :uses

        sig { params(socket: Socket, now: Float).void }
        def initialize(socket, now)
          @socket = socket
          @idle_since = now
          @uses = 0
        end

        # An idle keep-alive connection the server has closed shows as readable at
        # EOF. Checking costs one non-blocking read and saves a failed request.
        sig { returns(T::Boolean) }
        def stale?
          T.unsafe(@socket).read_nonblock(1, exception: false) != :wait_readable
        rescue IOError, SystemCallError
          true
        end

        sig { void }
        def close
          @socket.close unless @socket.closed?
        rescue IOError, SystemCallError
          nil
        end
      end

      # Keep-alive connections to one host and port. Thread-safe: a connection is
      # owned by exactly one caller between checkout and checkin.
      class Pool
        extend T::Sig

        sig { returns(Integer) }
        attr_reader :opened, :reused

        sig { params(host: String, port: Integer, clock: Monotonic, max_idle: Integer, idle_timeout: Float).void }
        def initialize(host:, port:, clock:, max_idle: 16, idle_timeout: 30.0)
          @host = host
          @port = port
          @clock = clock
          @max_idle = max_idle
          @idle_timeout = idle_timeout
          @idle = T.let([], T::Array[Connection])
          @mutex = Mutex.new
          @opened = 0
          @reused = 0
        end

        # An idle connection if a live one is waiting, else a new one opened within
        # the deadline. The boolean says whether it was reused.
        sig { params(deadline: Deadline).returns([Connection, T::Boolean]) }
        def checkout(deadline)
          while (connection = pop_idle)
            if connection.stale? || @clock.now - connection.idle_since > @idle_timeout
              connection.close
              next
            end
            @mutex.synchronize { @reused += 1 }
            return [connection, true]
          end
          [open_connection(deadline), false]
        end

        sig { params(connection: Connection).void }
        def checkin(connection)
          connection.idle_since = @clock.now
          extra = @mutex.synchronize do
            @idle.push(connection)
            @idle.length > @max_idle ? @idle.shift : nil
          end
          extra&.close
        end

        sig { returns(Integer) }
        def idle_count
          @mutex.synchronize { @idle.length }
        end

        sig { void }
        def close_all
          @mutex.synchronize { @idle.slice!(0..) }&.each(&:close)
        end

        private

        # Most recently used first: it is the least likely to have been closed by the
        # server's idle timeout, and the rest age out.
        sig { returns(T.nilable(Connection)) }
        def pop_idle
          @mutex.synchronize { @idle.pop }
        end

        sig { params(deadline: Deadline).returns(Connection) }
        def open_connection(deadline)
          addrinfo = resolve
          socket = Socket.new(addrinfo.afamily, Socket::SOCK_STREAM, 0)
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          connect(socket, addrinfo, deadline)
          @mutex.synchronize { @opened += 1 }
          Connection.new(socket, @clock.now)
        rescue DeadlineExceeded, ConnectionFailed
          socket&.close
          raise
        rescue SocketError, SystemCallError, IOError => e
          socket&.close
          raise ConnectionFailed, "connect: #{e.class}: #{e.message}"
        end

        # getaddrinfo blocks and cannot be given a deadline, so the name is resolved
        # once and the address kept for the life of the pool. RISKGATE_URL is expected
        # to be an address or a name the hosts file answers; see the design note.
        sig { returns(Addrinfo) }
        def resolve
          @resolve ||= T.let(Addrinfo.tcp(@host, @port), T.nilable(Addrinfo))
        end

        sig { params(socket: Socket, addrinfo: Addrinfo, deadline: Deadline).void }
        def connect(socket, addrinfo, deadline)
          return unless socket.connect_nonblock(addrinfo, exception: false) == :wait_writable

          Http.wait(socket, :writable, deadline, 'connecting')

          # Writable means the handshake finished, one way or the other; a second
          # connect reports which.
          socket.connect_nonblock(addrinfo)
        rescue Errno::EISCONN
          nil
        end
      end

      # Waits until the socket is ready, or raises once the deadline passes.
      sig { params(socket: Socket, direction: Symbol, deadline: Deadline, phase: String).void }
      def self.wait(socket, direction, deadline, phase)
        io = T.unsafe(socket) # IO#wait_readable and #wait_writable are missing from the stdlib RBI
        left = deadline.remaining!
        ready = direction == :readable ? io.wait_readable(left) : io.wait_writable(left)
        raise DeadlineExceeded, "deadline exceeded while #{phase}" unless ready
      end

      MAX_HEAD_BYTES = 16 * 1024
      MAX_BODY_BYTES = 64 * 1024
      READ_CHUNK = 16 * 1024

      # Sends `request_bytes` on the connection and reads one response, all within the
      # deadline. Raises DeadlineExceeded, ConnectionFailed or ProtocolError; the
      # caller must discard the connection after any of them.
      class Exchange
        extend T::Sig

        sig { params(socket: Socket, deadline: Deadline).void }
        def initialize(socket, deadline)
          @socket = socket
          @deadline = deadline
          @buffer = +''.b
          @received_any = false
        end

        # True once any byte of the response arrived. Before that, a reset on a reused
        # connection is the server having closed it while idle.
        sig { returns(T::Boolean) }
        def received_any?
          @received_any
        end

        sig { params(request_bytes: String).returns(Response) }
        def run(request_bytes)
          write_all(request_bytes)
          status, headers, http10 = read_head
          body = read_body(headers)
          connection = headers['connection'].to_s.downcase
          keep_alive = http10 ? connection == 'keep-alive' : connection != 'close'
          Response.new(status: status, headers: headers, body: body, keep_alive: keep_alive)
        rescue SystemCallError, IOError => e
          raise ConnectionFailed, "#{e.class}: #{e.message}"
        end

        private

        sig { params(bytes: String).void }
        def write_all(bytes)
          pending = bytes
          until pending.empty?
            written = @socket.write_nonblock(pending, exception: false)
            if written == :wait_writable
              Http.wait(@socket, :writable, @deadline, 'sending')
              next
            end
            pending = pending.byteslice(T.cast(written, Integer)..).to_s
          end
        end

        sig { returns([Integer, T::Hash[String, String], T::Boolean]) }
        def read_head
          split = index_of("\r\n\r\n", MAX_HEAD_BYTES, 'response head')
          head = T.must(@buffer.byteslice(0, split))
          @buffer = @buffer.byteslice((split + 4)..).to_s
          status_line, *lines = head.split("\r\n")
          match = %r{\AHTTP/1\.([01]) (\d{3})(?: |\z)}.match(status_line.to_s)
          raise ProtocolError, "bad status line #{status_line.to_s[0, 40].inspect}" unless match

          [Integer(match[2]), parse_headers(lines), match[1] == '0']
        end

        sig { params(lines: T::Array[String]).returns(T::Hash[String, String]) }
        def parse_headers(lines)
          lines.to_h do |line|
            name, value = line.split(':', 2)
            raise ProtocolError, "bad header line #{line[0, 40].inspect}" if value.nil? || name.to_s.strip.empty?

            [name.to_s.strip.downcase, value.strip]
          end
        end

        sig { params(headers: T::Hash[String, String]).returns(String) }
        def read_body(headers)
          if headers['transfer-encoding'].to_s.downcase.include?('chunked')
            read_chunked
          elsif (length = headers['content-length'])
            raise ProtocolError, "bad content-length #{length.inspect}" unless length.match?(/\A\d+\z/)

            take(Integer(length, 10))
          else
            read_to_eof
          end
        end

        sig { params(length: Integer).returns(String) }
        def take(length)
          raise ProtocolError, "body of #{length} bytes is over the cap" if length > MAX_BODY_BYTES

          fill while @buffer.bytesize < length
          taken = @buffer.byteslice(0, length).to_s
          @buffer = @buffer.byteslice(length..).to_s
          taken
        end

        sig { returns(String) }
        def read_chunked
          body = +''.b
          loop do
            eol = index_of("\r\n", 64, 'chunk size line')
            size_text = T.must(@buffer.byteslice(0, eol)).split(';', 2).first.to_s.strip
            raise ProtocolError, "bad chunk size #{size_text[0, 20].inspect}" unless size_text.match?(/\A\h+\z/)

            @buffer = @buffer.byteslice((eol + 2)..).to_s
            size = size_text.to_i(16)
            if size.zero?
              index_of("\r\n", MAX_HEAD_BYTES, 'trailer') # trailers are not used; wait for the final CRLF
              return body
            end
            body << take(size)
            raise ProtocolError, 'body over the cap' if body.bytesize > MAX_BODY_BYTES
            raise ProtocolError, 'chunk not followed by CRLF' unless take(2) == "\r\n"
          end
        end

        # Where `needle` starts in the buffer, reading more until it appears. A peer
        # that sends `limit` bytes without it is not speaking HTTP.
        sig { params(needle: String, limit: Integer, what: String).returns(Integer) }
        def index_of(needle, limit, what)
          loop do
            found = @buffer.index(needle)
            return found if found
            raise ProtocolError, "#{what} over #{limit} bytes" if @buffer.bytesize > limit

            fill
          end
        end

        sig { returns(String) }
        def read_to_eof
          loop { fill }
        rescue EOFError
          @buffer
        end

        # Reads whatever is available into the buffer, waiting at most until the
        # deadline. Raises EOFError at end of stream.
        sig { void }
        def fill
          loop do
            chunk = T.unsafe(@socket).read_nonblock(READ_CHUNK, exception: false)
            case chunk
            when :wait_readable
              Http.wait(@socket, :readable, @deadline, 'waiting for the response')
            when nil then raise EOFError, 'connection closed by RiskGate'
            else
              @received_any = true
              @buffer << chunk
              raise ProtocolError, 'response over the cap' if @buffer.bytesize > MAX_HEAD_BYTES + MAX_BODY_BYTES

              return
            end
          end
        end
      end
    end
  end
end
