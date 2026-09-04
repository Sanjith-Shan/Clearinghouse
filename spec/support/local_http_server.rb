# typed: false
# frozen_string_literal: true

require 'openssl'
require 'socket'

# A tiny HTTP/1.1 server on 127.0.0.1 for exercising SafeHttp against real sockets.
# The handler gets the client socket and the parsed request and writes whatever it
# likes, including nothing, garbage, or an endless body. With ssl_context it speaks TLS
# and records the SNI name each client sent.
class LocalHttpServer
  Request = Struct.new(:request_line, :headers, :body, keyword_init: true)

  attr_reader :port, :requests, :server_names

  def self.respond(socket, status, body = '', headers = {})
    head = ["HTTP/1.1 #{status} X", "Content-Length: #{body.bytesize}", 'Connection: close']
    headers.each { |k, v| head << "#{k}: #{v}" }
    socket.write("#{head.join("\r\n")}\r\n\r\n#{body}")
  end

  def initialize(ssl_context: nil, &handler)
    @handler = handler
    @ssl_context = ssl_context
    @requests = []
    @server_names = []
    @threads = []
    @mutex = Mutex.new
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    ssl_context&.servername_cb = lambda do |(_socket, name)|
      @mutex.synchronize { @server_names << name }
      nil
    end
    @acceptor = Thread.new { accept_loop }
  end

  def stop
    @acceptor.kill
    @mutex.synchronize { @threads.each(&:kill) }
    @server.close
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      @mutex.synchronize { @threads << Thread.new(client) { |c| serve(c) } }
    end
  rescue IOError
    nil
  end

  def serve(client)
    socket = @ssl_context ? OpenSSL::SSL::SSLSocket.new(client, @ssl_context).tap(&:accept) : client
    request = read_request(socket)
    @mutex.synchronize { @requests << request }
    @handler.call(socket, request)
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  ensure
    client.close unless client.closed?
  end

  def read_request(socket)
    request_line = socket.gets("\r\n").to_s.chomp
    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      name, value = line.chomp.split(':', 2)
      headers[name.downcase] = value.to_s.strip
    end
    Request.new(request_line: request_line, headers: headers,
                body: socket.read(headers.fetch('content-length', '0').to_i))
  end
end
