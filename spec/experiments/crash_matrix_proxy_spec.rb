# typed: false
# frozen_string_literal: true

require 'net/http'
require 'socket'
require_relative '../../sim/experiments/crash_matrix'

# The recording proxy writes an exchange down after relaying its last byte, so the
# caller can have its answer before the exchange is recorded. On a loaded machine
# that let crash_matrix_run_spec read a stage's exchanges before they were there.
# The slow `record` below stands in for the proxy's thread being descheduled.
RSpec.describe Experiments::CrashMatrix::RecordingProxy do
  let(:upstream) { TCPServer.new('127.0.0.1', 0) }
  let(:proxy) { described_class.new(upstream_port: upstream.addr[1]) }

  before do
    Thread.new do
      loop do
        socket = upstream.accept
        socket.readpartial(16_384)
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        socket.close
      end
    rescue IOError
      nil
    end
    allow(proxy).to receive(:record).and_wrap_original do |original, *args|
      sleep 0.3
      original.call(*args)
    end
    proxy.start
  end

  after do
    proxy.stop
    upstream.close
  end

  def get(path)
    Net::HTTP.get_response(URI("#{proxy.url}#{path}"))
  end

  it 'has every exchange the caller got an answer to by the time it reads them' do
    mark = proxy.mark
    expect(get('/operations/a').body).to eq('ok')
    expect(proxy.since(mark).map(&:to_s)).to eq(['GET /operations/a -> 200'])
  end

  it "does not let an earlier stage's exchange land after a later mark" do
    get('/operations/a')
    mark = proxy.mark
    get('/operations/b')
    expect(proxy.since(mark).map(&:to_s)).to eq(['GET /operations/b -> 200'])
  end
end
