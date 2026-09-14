# typed: true
# frozen_string_literal: true

require 'json'
require 'socket'
require_relative '../../lib/clearinghouse'

module Experiments
  module Webhooks
    # A hundred webhook endpoints in one process, for experiment 6. Every endpoint is a
    # path on one port, http://127.0.0.1:<port>/e/<n>, and behaves according to its kind:
    #
    #   healthy   answers 200 after 5 to 30 ms
    #   error     answers 500 after 5 to 30 ms
    #   hang      reads the request and never answers; closes after 60 s
    #   flapping  healthy and error in alternating 10 second periods of wall time
    #
    # Isolation is per endpoint id, not per host, so one port is as good as a hundred
    # for the queue under test; what matters is that a hung endpoint holds a connection
    # open. Each connection gets its own thread, so hung ones cost this server nothing.
    #
    # The log is the ground truth for the experiment: one JSON line per request, with
    # the wall time the response was written, the event id from the body, the status
    # sent, and whether the Clearinghouse-Signature verified against the endpoint's
    # secrets. A request to a hung endpoint is logged when it arrives, with status null.
    # A line is written only after the response was, so a 200 in the log is a delivery
    # the endpoint really completed.
    class HostileServer
      extend T::Sig

      KINDS = %w[healthy error hang flapping].freeze
      HANG_SECONDS = 60
      FLAP_PERIOD = 10.0

      # One endpoint's behaviour and the secrets its signatures should verify with.
      class Endpoint < T::Struct
        const :kind, String
        const :secrets, T::Array[String]
      end

      sig { returns(Integer) }
      attr_reader :port

      sig { params(endpoints: T::Hash[Integer, Endpoint], log: IO, seed: Integer, port: Integer).void }
      def initialize(endpoints:, log:, seed:, port: 0)
        @endpoints = endpoints
        @log = log
        @log_mutex = T.let(Mutex.new, Thread::Mutex)
        @rng = T.let(Random.new(seed), Random)
        @rng_mutex = T.let(Mutex.new, Thread::Mutex)
        @server = T.let(TCPServer.new('127.0.0.1', port), TCPServer)
        @port = T.let(@server.addr[1], Integer)
        @started = T.let(monotonic, Float)
      end

      sig { void }
      def run
        loop do
          client = @server.accept
          Thread.new(client) { |socket| serve(socket) }
        end
      rescue IOError
        nil
      end

      private

      sig { params(socket: TCPSocket).void }
      def serve(socket)
        path, headers, body = read_request(socket)
        number = path.to_s[%r{\A/e/(\d+)\z}, 1]&.to_i
        endpoint = number && @endpoints[number]
        return respond(socket, 404) unless number && endpoint

        if endpoint.kind == 'hang'
          # Log the attempt now, then hold the connection past any client timeout.
          record(number, body, headers, endpoint, nil)
          sleep HANG_SECONDS
        else
          status = answer(socket, endpoint)
          record(number, body, headers, endpoint, status)
        end
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close unless socket.closed?
      end

      # Answers after a small latency. A flapping endpoint is healthy in even periods.
      sig { params(socket: TCPSocket, endpoint: Endpoint).returns(Integer) }
      def answer(socket, endpoint)
        healthy = endpoint.kind == 'healthy' || (endpoint.kind == 'flapping' && flap_phase_ok?)
        sleep(latency)
        status = healthy ? 200 : 500
        respond(socket, status)
        status
      end

      sig { returns(T::Boolean) }
      def flap_phase_ok?
        ((monotonic - @started) / FLAP_PERIOD).floor.even?
      end

      sig { returns(Float) }
      def latency
        @rng_mutex.synchronize { 0.005 + (@rng.rand * 0.025) }
      end

      sig do
        params(number: Integer, body: String, headers: T::Hash[String, String], endpoint: Endpoint,
               status: T.nilable(Integer)).void
      end
      def record(number, body, headers, endpoint, status)
        event_id = begin
          JSON.parse(body)['id']
        rescue JSON::ParserError
          nil
        end
        header = headers.fetch('clearinghouse-signature', '')
        verified = Clearinghouse::Webhooks::Signature.verify(payload: body, header: header, secrets: endpoint.secrets,
                                                             now: Time.now.to_i, tolerance: 300)
        line = JSON.generate({ 't' => Time.now.to_f, 'ep' => number, 'kind' => endpoint.kind, 'evt' => event_id,
                               'status' => status, 'sig' => verified.valid? })
        @log_mutex.synchronize { @log.puts(line) }
      end

      sig { params(socket: TCPSocket).returns([T.nilable(String), T::Hash[String, String], String]) }
      def read_request(socket)
        request_line = socket.gets("\r\n").to_s
        headers = {}
        while (line = socket.gets("\r\n")) && line != "\r\n"
          name, value = line.chomp.split(':', 2)
          headers[name.to_s.downcase] = value.to_s.strip
        end
        body = socket.read(headers.fetch('content-length', '0').to_i).to_s
        [request_line.split[1], headers, body]
      end

      sig { params(socket: TCPSocket, status: Integer).void }
      def respond(socket, status)
        socket.write("HTTP/1.1 #{status} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      end

      sig { returns(Float) }
      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  # ruby exp/webhooks/hostile_server.rb <config.json> <log.jsonl>
  # config: {"port": 0, "seed": 1, "endpoints": {"<n>": {"kind": "...", "secrets": [...]}}}
  # Prints the port on stdout once listening.
  config = JSON.parse(File.read(ARGV.fetch(0)))
  endpoints = config.fetch('endpoints').to_h do |number, spec|
    endpoint = Experiments::Webhooks::HostileServer::Endpoint.new(kind: spec.fetch('kind'),
                                                                  secrets: spec.fetch('secrets'))
    [Integer(number, 10), endpoint]
  end
  File.open(ARGV.fetch(1), 'a') do |log|
    log.sync = true
    server = Experiments::Webhooks::HostileServer.new(endpoints: endpoints, log: log, seed: config.fetch('seed'),
                                                      port: config.fetch('port', 0))
    $stdout.puts(server.port)
    $stdout.flush
    server.run
  end
end
