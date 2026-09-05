# typed: false
# frozen_string_literal: true

require 'net/http'
require 'rbconfig'
require_relative 'sim_helper'

# bin/sim as a real subprocess, the way Clearinghouse and the experiments run it.
RSpec.describe AcquirerSim::App do
  describe 'bin/sim' do
    let(:port) { SimServer.closed_port }
    let(:root) { File.expand_path('../..', __dir__) }

    def wait_for_health(deadline)
      loop do
        return Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/health"))
      rescue SystemCallError, EOFError
        raise 'bin/sim did not come up' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end
    end

    it 'boots Puma on the given port, charges through the client, and exits on TERM' do
      pid = Process.spawn(RbConfig.ruby, File.join(root, 'bin/sim'), '--port', port.to_s,
                          chdir: root, out: File::NULL, err: File::NULL)
      begin
        expect(wait_for_health(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20).code).to eq('200')
        client = Clearinghouse::Acquirer::Client.new(clock: Clearinghouse::Clock::Test.new,
                                                     base_url: "http://127.0.0.1:#{port}")
        outcome = client.authorize(payment_method: 'pm_card_timeout', amount: Clearinghouse::Money.of(100, 'jpy'),
                                   capture: true, reference: 'pi_boot', idempotency_key: 'pi_boot:1')
        expect(outcome).to be_a(Clearinghouse::Acquirer::Unknown)
        expect(client.lookup('pi_boot:1')).to be_a(Clearinghouse::Acquirer::Approved)
      ensure
        Process.kill('TERM', pid)
        Process.wait(pid)
      end
    end
  end
end
