# typed: false
# frozen_string_literal: true

require 'socket'

RSpec.describe Clearinghouse::Risk::Http do
  let(:clock) { Clearinghouse::Risk::Monotonic::Real.new }

  describe Clearinghouse::Risk::Http::Connection do
    it 'is stale once the other end has closed, and live while it is open and quiet' do
      ours, theirs = Socket.pair(:UNIX, :STREAM)
      connection = described_class.new(ours, clock.now)
      expect(connection.stale?).to be(false)
      theirs.close
      expect(connection.stale?).to be(true)
    ensure
      ours&.close
    end

    it 'is stale if unexpected bytes are waiting, since the next response would be misread' do
      ours, theirs = Socket.pair(:UNIX, :STREAM)
      theirs.write('HTTP/1.1 200 OK')
      expect(described_class.new(ours, clock.now).stale?).to be(true)
    ensure
      [ours, theirs].each { |s| s&.close }
    end
  end

  describe Clearinghouse::Risk::Http::Pool do
    let(:server) { TCPServer.new('127.0.0.1', 0) }
    let(:manual) { Clearinghouse::Risk::Monotonic::Manual.new }
    let(:pool) do
      described_class.new(host: '127.0.0.1', port: server.addr[1], clock: manual, max_idle: 2, idle_timeout: 30.0)
    end
    let(:accepted) { [] }
    let!(:acceptor) { Thread.new { loop { accepted << server.accept } } }

    after do
      acceptor.kill
      pool.close_all
      accepted.each(&:close)
      server.close
    end

    def deadline
      Clearinghouse::Risk::Http::Deadline.new(Clearinghouse::Risk::Monotonic::Real.new, 1.0)
    end

    it 'hands back the most recently returned connection' do
      a, = pool.checkout(deadline)
      b, = pool.checkout(deadline)
      pool.checkin(a)
      pool.checkin(b)
      again, reused = pool.checkout(deadline)
      expect([again, reused]).to eq([b, true])
    end

    it 'keeps at most max_idle connections and closes the oldest extra' do
      connections = Array.new(3) { pool.checkout(deadline).first }
      connections.each { |c| pool.checkin(c) }
      expect(pool.idle_count).to eq(2)
      expect(connections.first.socket).to be_closed
    end

    it 'drops a connection idle longer than idle_timeout instead of reusing it' do
      first, = pool.checkout(deadline)
      pool.checkin(first)
      manual.advance(31.0)
      second, reused = pool.checkout(deadline)
      expect(reused).to be(false)
      expect(second).not_to eq(first)
      expect(first.socket).to be_closed
      expect(pool.opened).to eq(2)
    end
  end

  describe Clearinghouse::Risk::Http::Deadline do
    it 'counts down on the clock it is given and raises once spent' do
      manual = Clearinghouse::Risk::Monotonic::Manual.new
      deadline = described_class.new(manual, 0.05)
      expect(deadline.remaining!).to be_within(1e-9).of(0.05)
      manual.advance(0.05)
      expect(deadline.remaining).to eq(0.0)
      expect { deadline.remaining! }.to raise_error(Clearinghouse::Risk::Http::DeadlineExceeded)
    end
  end
end
