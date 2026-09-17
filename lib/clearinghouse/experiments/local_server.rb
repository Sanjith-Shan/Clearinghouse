# typed: true
# frozen_string_literal: true

require 'puma'
require 'puma/log_writer'
require 'puma/server'

module Clearinghouse
  module Experiments
    # A Rack app on Puma, on an ephemeral port of 127.0.0.1, inside this process.
    # Experiments run the acquirer simulator and the API this way so every call still
    # crosses a real TCP connection while the whole run shares one clock.
    class LocalServer
      extend T::Sig

      sig { returns(Integer) }
      attr_reader :port

      sig { params(app: T.untyped, threads: Integer).void }
      def initialize(app, threads: 8)
        @server = T.let(Puma::Server.new(app, nil, min_threads: 1, max_threads: threads,
                                                   log_writer: Puma::LogWriter.null), Puma::Server)
        @server.add_tcp_listener('127.0.0.1', 0)
        @port = T.let(Integer(@server.connected_ports.first), Integer)
        @server.run
      end

      sig { returns(String) }
      def url
        "http://127.0.0.1:#{port}"
      end

      sig { void }
      def stop
        @server.stop(true)
      end
    end
  end
end
