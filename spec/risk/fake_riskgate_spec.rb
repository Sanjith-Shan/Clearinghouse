# typed: false
# frozen_string_literal: true

require 'net/http'
require 'rbconfig'

# The fake is test infrastructure, but experiment 9's numbers rest on it behaving as
# configured, so it gets tests of its own.
RSpec.describe FakeRiskgate::Server do
  include FakeRiskgateHelper

  def post(path, body, headers = {})
    http = Net::HTTP.new('127.0.0.1', fake_riskgate.port)
    http.post(path, JSON.generate(body), { 'Content-Type' => 'application/json' }.merge(headers))
  end

  describe FakeRiskgate::Config do
    it 'decides by the first matching rule on amount, currency and risk fields, else the default' do
      config = described_class.new('rules' => [
                                     { 'name' => 'eur_big', 'currency' => 'eur', 'amount_gte' => 100,
                                       'decision' => 'review', 'score' => 60 },
                                     { 'name' => 'mid', 'amount_gte' => 50, 'amount_lt' => 100, 'decision' => 'block',
                                       'score' => 90, 'reasons' => ['r'] },
                                     { 'name' => 'vpn', 'risk_fields' => { 'vpn' => true }, 'decision' => 'block',
                                       'score' => 80 }
                                   ])
      decide = ->(body) { config.decide(body).values_at('decision', 'matched_rule') }

      expect(decide.call('amount' => 100, 'currency' => 'eur')).to eq(%w[review eur_big])
      expect(decide.call('amount' => 100, 'currency' => 'usd')).to eq(['allow', nil])
      expect(decide.call('amount' => 99, 'currency' => 'usd')).to eq(%w[block mid])
      expect(decide.call('amount' => 1, 'risk_fields' => { 'vpn' => true })).to eq(%w[block vpn])
    end

    it 'draws latency from a lognormal through p50 and p99' do
      config = described_class.new('latency_ms' => { 'p50' => 10, 'p99' => 40 }, 'seed' => 7)
      draws = Array.new(20_000) { config.latency_seconds * 1000 }.sort
      expect(draws[10_000]).to be_within(0.6).of(10)
      expect(draws[19_800]).to be_within(4).of(40)
    end

    it 'refuses keys it does not know, so a typo cannot silently do nothing' do
      expect { described_class.new('eror_rate' => 1) }.to raise_error(ArgumentError, /eror_rate/)
    end
  end

  it 'takes a new config over HTTP and reports its counters' do
    expect(post('/admin/config', { 'error_rate' => 1.0 }).code).to eq('200')
    expect(post('/v1/assess', { 'payment_id' => 'pi_1', 'amount' => 1 }, 'Idempotency-Key' => 'pi_1:1').code)
      .to eq('500')
    expect(post('/admin/config', { 'nope' => 1 }).code).to eq('400')
    stats = JSON.parse(Net::HTTP.get(URI("#{riskgate_url}/admin/stats")))
    expect(stats).to include('requests' => 4) # the stats request counts itself
  end

  it 'answers a body it cannot read with 400 instead of dying' do
    expect(post('/v1/assess', { 'payment_id' => 'pi_1', 'amount' => 'lots' }, 'Idempotency-Key' => 'x:1').code)
      .to eq('400')
    expect(post('/v1/assess', { 'payment_id' => 'pi_1', 'amount' => 5 }, 'Idempotency-Key' => 'x:2').code).to eq('200')
  end

  it 'closes every socket on crash in process, and refuses connections after' do
    reconfigure_fake('crash' => true)
    client = Clearinghouse::Risk::Client.new(base_url: riskgate_url, deadline_ms: 200)
    expect(client.assess(assess_request, attempt: 1).reason).to eq(Clearinghouse::Risk::UnavailableReason::Connection)
    sleep 0.05
    expect { TCPSocket.new('127.0.0.1', fake_riskgate.port).close }.to raise_error(Errno::ECONNREFUSED)
  end

  describe 'bin/fake-riskgate' do
    let(:port) { FakeRiskgateHelper.closed_port }
    let(:root) { File.expand_path('../..', __dir__) }

    def wait_for_health(pid)
      deadline = monotonic_ms + 20_000
      loop do
        return Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/health"))
      rescue SystemCallError, EOFError
        raise "bin/fake-riskgate did not come up (#{Process.wait2(pid, Process::WNOHANG).inspect})" if
          monotonic_ms > deadline

        sleep 0.05
      end
    end

    it 'serves assessments as a separate process and dies outright in crash mode' do
      pid = Process.spawn(RbConfig.ruby, File.join(root, 'bin/fake-riskgate'), '--port', port.to_s,
                          '--latency', '1,2', chdir: root, out: File::NULL, err: File::NULL)
      begin
        expect(wait_for_health(pid).code).to eq('200')
        client = Clearinghouse::Risk::Client.new(base_url: "http://127.0.0.1:#{port}", deadline_ms: 500)
        expect(client.assess(assess_request, attempt: 1)).to have_attributes(decision: 'allow')

        Net::HTTP.post(URI("http://127.0.0.1:#{port}/admin/config"), '{"crash": true}')
        expect(client.assess(assess_request, attempt: 1).reason)
          .to eq(Clearinghouse::Risk::UnavailableReason::Connection)
        _, status = Process.wait2(pid)
        expect(status.exitstatus).to eq(1)
        pid = nil
      ensure
        if pid
          Process.kill('TERM', pid)
          Process.wait(pid)
        end
      end
    end
  end
end
