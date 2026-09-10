# typed: false
# frozen_string_literal: true

require_relative '../../sim/fake_riskgate/lib/fake_riskgate'

# Runs FakeRiskgate::Server in this process on an ephemeral port, over real sockets.
# `crash` here closes every socket at once instead of exiting the process.
module FakeRiskgateHelper
  def self.included(base)
    base.let(:fake_config) { {} }
    base.let(:fake_riskgate) { FakeRiskgate::Server.new(config: FakeRiskgate::Config.new(fake_config)).start }
    base.let(:riskgate_url) { "http://127.0.0.1:#{fake_riskgate.port}" }
    base.after { fake_riskgate.stop }
  end

  def reconfigure_fake(overrides)
    fake_riskgate.configure(FakeRiskgate::Config.new(overrides))
  end

  def assess_request(payment_id: "pi_#{SecureRandom.hex(12)}", amount: 2_000, currency: 'usd', risk_fields: {})
    Clearinghouse::Risk::AssessRequest.new(payment_id: payment_id, created: 1_767_225_600,
                                           amount: Clearinghouse::Money.of(amount, currency),
                                           risk_fields: risk_fields)
  end

  # A port nothing listens on.
  def self.closed_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
  end
end
