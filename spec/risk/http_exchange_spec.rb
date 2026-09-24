# typed: false
# frozen_string_literal: true

require 'socket'

RSpec.describe Clearinghouse::Risk::Http::Exchange do
  let(:clock) { Clearinghouse::Risk::Monotonic::Real.new }
  let(:sockets) { [] }
  let(:writers) { [] }

  after do
    sockets.each { |s| s.close unless s.closed? }
    writers.each(&:join)
  end

  # Runs one exchange over a fresh socket pair where the "server" has already
  # written `raw` and, if close is set, hung up.
  def exchange(raw, close: true, seconds: 0.2)
    ours, theirs = Socket.pair(:UNIX, :STREAM)
    sockets.push(ours, theirs)
    # A thread, because a UNIX socket buffer is smaller than the largest response here.
    writer = Thread.new do
      theirs.write(raw)
      theirs.close_write if close
    rescue IOError, SystemCallError
      nil
    end
    writers << writer
    described_class.new(ours, Clearinghouse::Risk::Http::Deadline.new(clock, seconds)).run("GET / HTTP/1.1\r\n\r\n")
  end

  def expect_protocol_error(raw, message)
    expect { exchange(raw) }.to raise_error(Clearinghouse::Risk::Http::ProtocolError, message)
  end

  it 'reads a Content-Length body and keeps an HTTP/1.1 connection alive by default' do
    response = exchange("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-A: b\r\n\r\nhi", close: false)
    expect(response).to have_attributes(status: 200, body: 'hi', keep_alive: true, headers: include('x-a' => 'b'))
  end

  it 'treats HTTP/1.0 as close unless it asks for keep-alive' do
    expect(exchange("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n").keep_alive).to be(false)
  end

  it 'reads to end of stream when there is no length' do
    expect(exchange("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nall of it")).to have_attributes(body: 'all of it',
                                                                                                 keep_alive: false)
  end

  it 'refuses what it cannot trust' do
    expect_protocol_error("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n", /bad content-length/)
    expect_protocol_error("HTTP/1.1 200 OK\r\nno colon here\r\n\r\n", /bad header line/)
    expect_protocol_error("HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n", /over the cap/)
    expect_protocol_error("HTTP/1.1 200 OK\r\nX: #{'a' * 20_000}", /response head over/)
  end

  it 'caps the body however it is framed: many chunks, or no length at all' do
    chunk = "#{(40 * 1024).to_s(16)}\r\n#{'a' * 40 * 1024}\r\n"
    expect_protocol_error("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n#{chunk}#{chunk}",
                          /\Abody over the cap\z/)
    expect_protocol_error("HTTP/1.1 200 OK\r\n\r\n#{'a' * 90_000}", /\Aresponse over the cap\z/)
  end

  it 'refuses a broken chunked body' do
    expect_protocol_error("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", /bad chunk size/)
    expect_protocol_error("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhiXX", /not followed by CRLF/)
  end

  it 'reports a response cut off mid-body as a connection failure' do
    expect { exchange("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc") }
      .to raise_error(Clearinghouse::Risk::Http::ConnectionFailed, /closed by RiskGate/)
  end

  it 'times out on a server that answers with half a head and then nothing' do
    expect { exchange("HTTP/1.1 200 OK\r\n", close: false, seconds: 0.05) }
      .to raise_error(Clearinghouse::Risk::Http::DeadlineExceeded)
  end
end
