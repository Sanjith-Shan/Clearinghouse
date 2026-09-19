# typed: false
# frozen_string_literal: true

# Everything here runs over real sockets against a real server in this process: the
# fake RiskGate, or LocalHttpServer when a test needs bytes no HTTP server would send.
RSpec.describe Clearinghouse::Risk::Client do
  include FakeRiskgateHelper

  # Deadline tests measure wall time on a machine that may be running other suites.
  # The deadline is 80 ms and a call may overrun it by at most EPSILON_MS: the cost
  # of one wake-up after the last wait, not of another wait.
  let(:deadline_ms) { 80 }
  let(:epsilon_ms) { 40 }
  let(:reason) { Clearinghouse::Risk::UnavailableReason }
  let(:breaker_clock) { Clearinghouse::Risk::Monotonic::Manual.new }
  let(:breaker) { Clearinghouse::Risk::CircuitBreaker.new(clock: breaker_clock, consecutive: 5, cooldown: 2.0) }
  let(:client) { described_class.new(base_url: riskgate_url, deadline_ms: deadline_ms, breaker: breaker) }
  let(:servers) { [] }

  after do
    client.close
    servers.each(&:stop)
  end

  def timed
    started = monotonic_ms
    result = yield
    [result, monotonic_ms - started]
  end

  # How late this process wakes up right now: the worst overrun of a few 5 ms
  # sleeps. On a quiet machine it is about a millisecond; under heavy load it is
  # tens or hundreds. The load-tolerant bounds below allow the deadline, the one
  # wake-up the design allows (epsilon), and a few of these, so they still fail
  # if the client waited again after the deadline (another 80 ms wait or more on
  # a quiet machine, the whole hang or handshake timeout under load) but not
  # because the machine was busy. The strict bounds are tagged :timing.
  def scheduling_lag_ms
    Array.new(5) { timed { sleep 0.005 }.last - 5 }.max
  end

  def loaded_bound_ms
    deadline_ms + epsilon_ms + (4 * scheduling_lag_ms)
  end

  def local_server(&)
    server = LocalHttpServer.new(&)
    servers << server
    server
  end

  describe 'a healthy RiskGate' do
    let(:fake_config) do
      { 'rules' => [
        { 'name' => 'huge_amount', 'amount_gte' => 1_000_000, 'decision' => 'block', 'score' => 97,
          'reasons' => ['amount is far above this card\'s usual'] },
        { 'name' => 'new_country', 'risk_fields' => { 'ip_country' => 'XX' }, 'decision' => 'review',
          'score' => 71, 'reasons' => ['first payment from this country', 'new device'] }
      ] }
    end

    it 'returns a typed Assessment for allow, review and block' do
      allow_result = client.assess(assess_request(amount: 500), attempt: 1)
      review = client.assess(assess_request(risk_fields: { 'ip_country' => 'XX' }), attempt: 1)
      block = client.assess(assess_request(amount: 5_000_000), attempt: 1)

      expect(allow_result).to have_attributes(decision: 'allow', risk_score: 5, matched_rule: nil, reasons: [],
                                              ruleset_version: 'fake-1', replayed: false)
      expect(review).to have_attributes(decision: 'review', risk_score: 71, matched_rule: 'new_country',
                                        reasons: ['first payment from this country', 'new device'])
      expect(block).to have_attributes(decision: 'block', risk_score: 97, matched_rule: 'huge_amount')
      expect([allow_result, review, block].map(&:assessment_id).uniq.length).to eq(3)
    end

    it 'sends the contract: path, body, Idempotency-Key and the remaining deadline' do
      client.assess(assess_request(payment_id: 'pi_abc', amount: 1234, currency: 'eur',
                                   risk_fields: { 'card_country' => 'DE' }), attempt: 3)
      request = fake_riskgate.requests.last

      expect([request.verb, request.path]).to eq(%w[POST /v1/assess])
      expect(JSON.parse(request.body)).to eq('payment_id' => 'pi_abc', 'created' => 1_767_225_600, 'amount' => 1234,
                                             'currency' => 'eur', 'risk_fields' => { 'card_country' => 'DE' })
      expect(request.headers).to include('idempotency-key' => 'pi_abc:3', 'content-type' => 'application/json')
      expect(Integer(request.headers.fetch('riskgate-deadline-ms'))).to be_between(1, deadline_ms)
    end

    it 'gets the stored assessment back when the same attempt is sent again, and a new one for a new attempt' do
      request = assess_request
      first = client.assess(request, attempt: 1)
      again = client.assess(request, attempt: 1)
      next_attempt = client.assess(request, attempt: 2)

      expect(again).to have_attributes(assessment_id: first.assessment_id, replayed: true)
      expect(next_attempt.assessment_id).not_to eq(first.assessment_id)
      expect(fake_riskgate.stats).to include('assessments' => 2, 'replays' => 1)
    end

    it 'reuses one keep-alive connection for sequential calls' do
      results = Array.new(20) { client.assess(assess_request, attempt: 1) }

      expect(results).to all(be_a(Clearinghouse::Risk::Assessment))
      expect(fake_riskgate.stats['connections_opened']).to eq(1)
      expect([client.pool.opened, client.pool.reused]).to eq([1, 19])
    end

    context 'with 16 callers at once' do
      # This checks correctness under concurrency, not latency: 16 client threads and
      # 16 fake-server threads share one GVL here, so an 80 ms deadline is sometimes
      # missed for reasons that have nothing to do with the client.
      let(:deadline_ms) { 2_000 }

      it 'serves them all without mixing up their answers' do
        keys_and_results = Array.new(16) do |t|
          Thread.new do
            Array.new(20) do |i|
              request = assess_request(payment_id: "pi_t#{t}_#{i}")
              [request.idempotency_key(1), client.assess(request, attempt: 1)]
            end
          end
        end.flat_map(&:value)

        expect(keys_and_results.map(&:last)).to all(be_a(Clearinghouse::Risk::Assessment))
        keys_and_results.each do |key, result|
          expect(result.assessment_id).to eq(fake_riskgate.assessment_id_for(key))
        end
        expect(fake_riskgate.stats['connections_opened']).to be <= 16
        expect(client.pool.reused).to be >= 320 - 16
      end
    end
  end

  describe 'the deadline' do
    it 'holds when RiskGate accepts the request and never answers' do
      reconfigure_fake('hang' => true)
      result, elapsed = timed { client.assess(assess_request, attempt: 1) }

      expect(result).to have_attributes(reason: reason::Timeout)
      expect(elapsed).to be >= deadline_ms - 1
      expect(elapsed).to be < loaded_bound_ms
    end

    it 'holds when RiskGate never answers, to within one wake-up', :timing do
      reconfigure_fake('hang' => true)
      _, elapsed = timed { client.assess(assess_request, attempt: 1) }
      expect(elapsed).to be < deadline_ms + epsilon_ms
    end

    it 'holds when RiskGate is merely slower than the deadline' do
      reconfigure_fake('latency_ms' => { 'p50' => 300, 'p99' => 300 })
      result, elapsed = timed { client.assess(assess_request, attempt: 1) }

      # A timeout at all means the client gave up before the 300 ms answer arrived.
      expect(result.reason).to eq(reason::Timeout)
      expect(elapsed).to be < loaded_bound_ms
    end

    it 'holds when RiskGate is merely slower, to within one wake-up', :timing do
      reconfigure_fake('latency_ms' => { 'p50' => 300, 'p99' => 300 })
      _, elapsed = timed { client.assess(assess_request, attempt: 1) }
      expect(elapsed).to be < deadline_ms + epsilon_ms
    end

    it 'covers the whole response, not each read: a server dripping a byte every 10 ms is cut off' do
      body = JSON.generate('assessment_id' => 'asm_1', 'decision' => 'allow', 'risk_score' => 1,
                           'matched_rule' => nil, 'reasons' => [], 'ruleset_version' => 'v1')
      drip = local_server do |socket, _request|
        "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}".each_char do |c|
          socket.write(c)
          sleep 0.01
        end
      end
      slow_client = described_class.new(base_url: "http://127.0.0.1:#{drip.port}", deadline_ms: deadline_ms)
      result, elapsed = timed { slow_client.assess(assess_request, attempt: 1) }

      expect(result).to have_attributes(reason: reason::Timeout)
      expect(result.detail).to include('waiting for the response')
      # The whole drip takes over a second; a per-read timeout would sit through all of it.
      expect(elapsed).to be < loaded_bound_ms
    end

    it 'covers connecting: an address that never completes the handshake times out or fails, within the deadline' do
      # 10.255.255.1 is unroutable on most networks (SYN goes nowhere); some sandboxes
      # refuse it outright instead. Either way the call must not outlive the deadline.
      blackhole = described_class.new(base_url: 'http://10.255.255.1:80', deadline_ms: deadline_ms)
      result, elapsed = timed { blackhole.assess(assess_request, attempt: 1) }

      expect([reason::Timeout, reason::Connection]).to include(result.reason)
      # Without the deadline this waits for the kernel's handshake timeout, over a minute.
      expect(elapsed).to be < loaded_bound_ms
    end

    it 'covers the whole response and connecting, to within one wake-up', :timing do
      body = JSON.generate('assessment_id' => 'asm_1', 'decision' => 'allow', 'risk_score' => 1,
                           'matched_rule' => nil, 'reasons' => [], 'ruleset_version' => 'v1')
      drip = local_server do |socket, _request|
        "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}".each_char do |c|
          socket.write(c)
          sleep 0.01
        end
      end
      clients = [described_class.new(base_url: "http://127.0.0.1:#{drip.port}", deadline_ms: deadline_ms),
                 described_class.new(base_url: 'http://10.255.255.1:80', deadline_ms: deadline_ms)]
      elapsed = clients.map { |c| timed { c.assess(assess_request, attempt: 1) }.last }
      expect(elapsed).to all(be < deadline_ms + epsilon_ms)
    end
  end

  describe 'failures, which all come back as Unavailable' do
    it 'reports a 500 as http_status with the status' do
      reconfigure_fake('error_rate' => 1.0)
      expect(client.assess(assess_request, attempt: 1)).to have_attributes(reason: reason::HttpStatus, status: 500)
    end

    it 'reports a truncated JSON body as malformed' do
      reconfigure_fake('malformed_rate' => 1.0)
      expect(client.assess(assess_request, attempt: 1).reason).to eq(reason::Malformed)
    end

    it 'reports a well-formed body that breaks the contract as malformed' do
      bad = local_server do |socket, _|
        LocalHttpServer.respond(socket, 200, JSON.generate('assessment_id' => 'a', 'decision' => 'allow',
                                                           'risk_score' => 150, 'reasons' => [],
                                                           'ruleset_version' => 'v'))
      end
      result = described_class.new(base_url: "http://127.0.0.1:#{bad.port}").assess(assess_request, attempt: 1)
      expect(result).to have_attributes(reason: reason::Malformed, detail: include('risk_score 150'))
    end

    it 'reports bytes that are not HTTP as malformed' do
      garbage = local_server { |socket, _| socket.write("SSH-2.0-OpenSSH_9.6\r\n\r\n") }
      result = described_class.new(base_url: "http://127.0.0.1:#{garbage.port}").assess(assess_request, attempt: 1)
      expect(result).to have_attributes(reason: reason::Malformed, detail: include('bad status line'))
    end

    it 'reports a refused connection as connection, at once' do
      refused = described_class.new(base_url: "http://127.0.0.1:#{FakeRiskgateHelper.closed_port}")
      result, elapsed = timed { refused.assess(assess_request, attempt: 1) }
      expect(result.reason).to eq(reason::Connection)
      # Far less than the deadline: a refusal is not waited out.
      expect(elapsed).to be < 20 + (4 * scheduling_lag_ms)
    end

    it 'reports a refused connection within 20 ms', :timing do
      refused = described_class.new(base_url: "http://127.0.0.1:#{FakeRiskgateHelper.closed_port}")
      expect(timed { refused.assess(assess_request, attempt: 1) }.last).to be < 20
    end

    it 'reports a connection closed before any answer as connection' do
      hangup = local_server { |_socket, _| nil }
      result = described_class.new(base_url: "http://127.0.0.1:#{hangup.port}").assess(assess_request, attempt: 1)
      expect(result.reason).to eq(reason::Connection)
    end

    it 'reads a chunked response, and does not pool a connection the server said it would close' do
      body = JSON.generate('assessment_id' => 'asm_c', 'decision' => 'review', 'risk_score' => 60,
                           'matched_rule' => 'r', 'reasons' => ['x'], 'ruleset_version' => 7)
      chunked = local_server do |socket, _|
        socket.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" \
                     "#{body[0, 10].bytesize.to_s(16)}\r\n#{body[0, 10]}\r\n" \
                     "#{body[10..].bytesize.to_s(16)}\r\n#{body[10..]}\r\n0\r\n\r\n")
      end
      chunk_client = described_class.new(base_url: "http://127.0.0.1:#{chunked.port}")
      expect(chunk_client.assess(assess_request, attempt: 1))
        .to have_attributes(assessment_id: 'asm_c', decision: 'review', ruleset_version: '7')
      expect(chunk_client.pool.idle_count).to eq(0)
    end
  end

  describe 'stale keep-alive connections' do
    it 'reconnects when RiskGate closed the idle connection, without failing the call' do
      reconfigure_fake('close_after' => 1)
      results = Array.new(5) do
        client.assess(assess_request, attempt: 1).tap { sleep 0.01 } # let the server's close land
      end

      expect(results).to all(be_a(Clearinghouse::Risk::Assessment))
      expect(fake_riskgate.stats['connections_opened']).to eq(5)
    end

    it 'retries once on a fresh connection when a reused one is reset before any answer' do
      client.assess(assess_request, attempt: 1) # one pooled connection
      # The server reads the next request and closes without answering. The pooled
      # connection looked healthy, so this is the idle-close race seen from our side.
      reconfigure_fake('drop_next' => 1)
      result = client.assess(assess_request, attempt: 1)

      expect(result).to be_a(Clearinghouse::Risk::Assessment)
      expect(fake_riskgate.stats).to include('connections_opened' => 2, 'drops' => 1)
    end
  end

  describe 'the circuit breaker' do
    before { reconfigure_fake('error_rate' => 1.0) }

    it 'opens after consecutive failures and then fails fast without touching the network' do
      5.times { client.assess(assess_request, attempt: 1) }
      requests_before = fake_riskgate.stats['requests']

      results, elapsed = timed { Array.new(200) { client.assess(assess_request, attempt: 1) } }

      expect(results.map(&:reason).uniq).to eq([reason::BreakerOpen])
      expect(fake_riskgate.stats['requests']).to eq(requests_before)
      expect(elapsed / 200).to be < 1.0 # ms per call
    end

    it 'lets a probe through after the cool-down and closes when RiskGate is back' do
      5.times { client.assess(assess_request, attempt: 1) }
      reconfigure_fake({})
      expect(client.assess(assess_request, attempt: 1).reason).to eq(reason::BreakerOpen)

      breaker_clock.advance(2.0)
      probe = client.assess(assess_request, attempt: 1)

      expect(probe).to be_a(Clearinghouse::Risk::Assessment)
      expect(breaker.state).to eq(Clearinghouse::Risk::CircuitBreaker::State::Closed)
      expect(client.assess(assess_request, attempt: 1)).to be_a(Clearinghouse::Risk::Assessment)
    end

    it 'reopens when the probe fails' do
      5.times { client.assess(assess_request, attempt: 1) }
      breaker_clock.advance(2.0)

      expect(client.assess(assess_request, attempt: 1).reason).to eq(reason::HttpStatus)
      expect(client.assess(assess_request, attempt: 1).reason).to eq(reason::BreakerOpen)
    end

    it 'opens on timeouts too' do
      reconfigure_fake('hang' => true)
      5.times { client.assess(assess_request, attempt: 1) }
      expect(breaker.state).to eq(Clearinghouse::Risk::CircuitBreaker::State::Open)
    end

    it 'does not count a 4xx against RiskGate: that is a bug on our side, and opening would hide it' do
      reconfigure_fake('error_rate' => 1.0, 'error_status' => 400)
      results = Array.new(10) { client.assess(assess_request, attempt: 1) }

      expect(results.map(&:status).uniq).to eq([400])
      expect(breaker.state).to eq(Clearinghouse::Risk::CircuitBreaker::State::Closed)
    end
  end

  it 'refuses a URL it cannot honour' do
    expect { described_class.new(base_url: 'https://riskgate.internal') }.to raise_error(ArgumentError, /http:/)
    expect { described_class.new(base_url: 'http://127.0.0.1:1', deadline_ms: 0) }.to raise_error(ArgumentError)
  end
end
