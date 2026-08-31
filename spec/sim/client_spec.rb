# typed: false
# frozen_string_literal: true

require_relative 'sim_helper'

# Every outcome of Clearinghouse::Acquirer::Client, each produced by a real server over
# a real socket. The distinction that matters is Unknown (the acquirer may have
# committed) against Unavailable (it definitely did not), so each Unknown test also
# shows the acquirer did commit, and each Unavailable test shows it did not.
RSpec.describe Clearinghouse::Acquirer::Client do
  let(:server) { SimServer.start }
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 5, 4, 3, 2, 1)) }
  let(:client) { described_class.new(clock: clock, base_url: server.url, read_timeout: 2) }
  let(:acquirer) { Clearinghouse::Acquirer }

  after { server.stop }

  def usd(amount)
    Clearinghouse::Money.of(amount, 'usd')
  end

  def authorize(payment_method = 'pm_card_visa', key: 'pi_1:1', amount: 5_000, via: client)
    via.authorize(payment_method: payment_method, amount: usd(amount), capture: false, reference: 'pi_1',
                  idempotency_key: key)
  end

  describe 'Approved and Declined' do
    it 'approves, sending Sim-Time from the clock and the idempotency key' do
      outcome = authorize
      expect(outcome).to be_a(acquirer::Approved)
      expect(outcome.operation).to have_attributes(type: 'authorize', status: 'approved', amount: 5_000,
                                                   currency: 'usd', idempotency_key: 'pi_1:1',
                                                   created_at: clock.now)
    end

    it 'declines with the acquirer code' do
      outcome = authorize('pm_card_insufficientFunds')
      expect(outcome).to be_a(acquirer::Declined)
      expect(outcome.code).to eq('insufficient_funds')
    end

    it 'runs capture, refund and void, and reports a business-rule failure as Declined' do
      ref = authorize.operation.acquirer_reference
      too_much = client.capture(acquirer_reference: ref, amount: usd(5_001), idempotency_key: 'c0')
      expect(too_much).to have_attributes(code: 'amount_exceeds_authorized')
      expect(client.capture(acquirer_reference: ref, amount: usd(4_000), idempotency_key: 'c1'))
        .to be_a(acquirer::Approved)
      expect(client.refund(acquirer_reference: ref, amount: usd(1_000), idempotency_key: 'r1'))
        .to be_a(acquirer::Approved)
      expect(client.void(acquirer_reference: ref, idempotency_key: 'v1')).to have_attributes(code: 'already_captured')
    end
  end

  describe 'Unknown: the request was sent and no answer came back' do
    it 'is Unknown when the acquirer commits and drops the connection, and lookup finds the charge' do
      outcome = authorize('pm_card_timeout')
      expect(outcome).to be_a(acquirer::Unknown)
      expect(outcome.reason).to include('no response after sending')

      found = client.lookup('pi_1:1')
      expect(found).to be_a(acquirer::Approved)
      expect(found.operation.amount).to eq(5_000)
      expect(authorize('pm_card_timeout').serialize).to eq(found.serialize) # the retry replays it
      expect(server.simulator.authorizations.size).to eq(1)
    end

    it 'is Unknown on drop_after_commit for any operation' do
      ref = authorize.operation.acquirer_reference
      client.capture(acquirer_reference: ref, amount: usd(5_000), idempotency_key: 'c1')
      server.simulator.configure('drop_after_commit_rate' => 1.0)
      expect(client.refund(acquirer_reference: ref, amount: usd(100), idempotency_key: 'r1'))
        .to be_a(acquirer::Unknown)
      expect(client.lookup('r1')).to be_a(acquirer::Approved)
    end

    it 'is Unknown on a read timeout, and the acquirer really does commit after the client gave up' do
      server.simulator.configure('latency_ms' => { 'p50' => 300, 'p99' => 300 })
      impatient = described_class.new(clock: clock, base_url: server.url, read_timeout: 0.05)
      expect(authorize(via: impatient)).to be_a(acquirer::Unknown)
      expect(server.simulator.operation('pi_1:1')).to be_nil # not yet: still sleeping

      server.simulator.configure('latency_ms' => { 'p50' => 0, 'p99' => 0 })
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      until server.simulator.operation('pi_1:1') || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
      expect(client.lookup('pi_1:1')).to be_a(acquirer::Approved)
    end

    it 'is Unknown when the server accepts the connection and closes it unread' do
      listener = TCPServer.new('127.0.0.1', 0)
      acceptor = Thread.new { listener.accept.close }
      rude = described_class.new(clock: clock, base_url: "http://127.0.0.1:#{listener.addr[1]}")
      expect(authorize(via: rude)).to be_a(acquirer::Unknown)
      acceptor.join
      listener.close
    end

    it 'is Unknown on a 500 or an unreadable 200, which could come from a crash after commit' do
      stub = SimServer.new(nil, ->(_env) { [500, {}, ['boom']] })
      expect(authorize(via: described_class.new(clock: clock, base_url: stub.url))).to be_a(acquirer::Unknown)
      stub.stop
      garbage = SimServer.new(nil, ->(_env) { [200, {}, ['{"half":']] })
      expect(authorize(via: described_class.new(clock: clock, base_url: garbage.url))).to be_a(acquirer::Unknown)
      garbage.stop
    end
  end

  describe 'Unavailable: definitely not processed' do
    it 'is Unavailable when the connection is refused' do
      down = described_class.new(clock: clock, base_url: "http://127.0.0.1:#{SimServer.closed_port}")
      expect(authorize(via: down)).to be_a(acquirer::Unavailable)
      expect(down.lookup('pi_1:1')).to be_a(acquirer::Unavailable)
    end

    it 'is Unavailable on a 503, and lookup confirms nothing was committed' do
      server.simulator.configure('error_rate' => 1.0)
      outcome = authorize
      expect(outcome).to be_a(acquirer::Unavailable)
      expect(outcome.reason).to eq('acquirer answered 503')
      expect(client.lookup('pi_1:1')).to be_a(acquirer::Unavailable) # the status query is down too

      server.simulator.configure('error_rate' => 0.0)
      expect(client.lookup('pi_1:1')).to be_a(acquirer::NotFound)
      expect(server.simulator.authorizations).to be_empty
    end
  end

  describe 'lookup' do
    it 'returns NotFound for a key never used, and escapes the key in the path' do
      expect(client.lookup('pi_1:attempt/1 x')).to be_a(acquirer::NotFound)
      authorize(key: 'pi_1:attempt/1 x')
      expect(client.lookup('pi_1:attempt/1 x')).to be_a(acquirer::Approved)
    end

    it 'raises rather than report NotFound on a 404 that is not the status query answering' do
      wrong = described_class.new(clock: clock, base_url: "#{server.url}/v9")
      expect { wrong.lookup('k') }.to raise_error(acquirer::ProtocolError) { |e| expect(e.code).to eq('no_route') }
    end

    it 'is Unavailable, never NotFound, on a 500' do
      stub = SimServer.new(nil, ->(_env) { [500, {}, ['boom']] })
      expect(described_class.new(clock: clock, base_url: stub.url).lookup('k')).to be_a(acquirer::Unavailable)
      stub.stop
    end
  end

  describe 'caller bugs' do
    it 'raises ProtocolError when a key is reused with a different body' do
      authorize(amount: 5_000)
      expect { authorize(amount: 5_001) }
        .to raise_error(acquirer::ProtocolError) { |e|
              expect(e).to have_attributes(status: 409, code: 'idempotency_key_mismatch')
            }
    end

    it 'raises ProtocolError on a malformed request' do
      expect { authorize('pm_card_unknown') }
        .to raise_error(acquirer::ProtocolError) { |e| expect(e.code).to eq('invalid_request') }
    end
  end
end
