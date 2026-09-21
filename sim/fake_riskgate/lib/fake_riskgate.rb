# typed: true
# frozen_string_literal: true

require 'json'
require 'openssl'
require 'socket'
require 'sorbet-runtime'

# A stand-in for RiskGate's POST /v1/assess, for tests and for experiment 9 when the
# real Go service is not running. It speaks the contract in docs/design/interfaces.md
# and misbehaves on command: latency from a lognormal fitted to p50 and p99, a share
# of 500s, a share of malformed 200s, hanging without answering, and crashing.
# It also takes Clearinghouse's webhooks at POST /v1/webhooks/clearinghouse, checks
# the signature against `webhook_secrets`, and counts what arrived, so experiment 8
# can show events flowing back without the Go service.
#
# It is a raw TCP server rather than a Rack app because the misbehaviour that
# matters is below HTTP: holding a connection open and silent, closing idle
# keep-alive connections, dying with sockets open. It also counts connections,
# which is how the tests prove the client reuses them.
module FakeRiskgate
  # What the fake does. Replaced wholesale by POST /admin/config.
  class Config
    extend T::Sig

    Z99 = 2.3263478740408408

    DEFAULTS = T.let({
      'seed' => 1,
      'ruleset_version' => 'fake-1',
      # Checked in order; the first match decides. Each rule may constrain
      # amount_gte, amount_lt, currency and risk_fields (exact values).
      'rules' => [],
      'default' => { 'decision' => 'allow', 'score' => 5, 'reasons' => [] },
      'latency_ms' => { 'p50' => 0, 'p99' => 0 },
      'error_rate' => 0.0,
      'error_status' => 500,
      'malformed_rate' => 0.0,
      # Read the request and never answer (hang_rate is the share of requests).
      'hang' => false,
      'hang_rate' => 0.0,
      # The next assess request crashes the server: the process exits in
      # bin/fake-riskgate, every socket is closed at once in process.
      'crash' => false,
      # Close a keep-alive connection after this many requests on it (0: never).
      'close_after' => 0,
      # Read the next N assess requests and close the connection without answering.
      'drop_next' => 0,
      # Secrets POST /v1/webhooks/clearinghouse accepts signatures from, and the
      # allowed timestamp skew in seconds. No secrets: every webhook is rejected.
      'webhook_secrets' => [],
      'webhook_tolerance' => 300
    }.freeze, T::Hash[String, T.untyped])

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :values

    sig { params(overrides: T::Hash[String, T.untyped]).void }
    def initialize(overrides = {})
      unknown = overrides.keys - DEFAULTS.keys
      raise ArgumentError, "unknown config keys: #{unknown.join(', ')}" unless unknown.empty?

      @values = T.let(DEFAULTS.merge(overrides), T::Hash[String, T.untyped])
      @random = T.let(Random.new(Integer(@values['seed'])), Random)
    end

    sig { params(key: String).returns(T.untyped) }
    def [](key)
      @values.fetch(key)
    end

    sig { returns(Float) }
    def draw
      @random.rand
    end

    sig { returns(Float) }
    def latency_seconds
      p50 = Float(self['latency_ms'].fetch('p50', 0))
      p99 = Float(self['latency_ms'].fetch('p99', p50))
      return 0.0 if p50.zero?

      sigma = Math.log([p99, p50].max / p50) / Z99
      z = Math.sqrt(-2.0 * Math.log(1.0 - draw)) * Math.cos(2.0 * Math::PI * draw)
      p50 * Math.exp(sigma * z) / 1000.0
    end

    # The assessment for a request body, from the first matching rule.
    sig { params(body: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def decide(body)
      rule = self['rules'].find { |r| matches?(r, body) }
      chosen = rule || self['default']
      { 'decision' => chosen.fetch('decision'), 'risk_score' => chosen.fetch('score'),
        'matched_rule' => rule&.fetch('name', nil), 'reasons' => chosen.fetch('reasons', []),
        'ruleset_version' => self['ruleset_version'] }
    end

    private

    sig { params(rule: T::Hash[String, T.untyped], body: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def matches?(rule, body)
      amount = Integer(body['amount'] || 0)
      return false if rule.key?('amount_gte') && amount < rule['amount_gte']
      return false if rule.key?('amount_lt') && amount >= rule['amount_lt']
      return false if rule.key?('currency') && body['currency'] != rule['currency']

      fields = body['risk_fields'].is_a?(Hash) ? body['risk_fields'] : {}
      rule.fetch('risk_fields', {}).all? { |k, v| fields[k] == v }
    end
  end

  # One parsed request.
  Request = Struct.new(:verb, :path, :headers, :body, keyword_init: true)

  # The server. Thread per connection, keep-alive, state behind one mutex.
  class Server
    extend T::Sig

    # What a handler returns: whether the connection may carry another request.
    KEEP_OPEN = true
    CLOSE = false

    sig { returns(Integer) }
    attr_reader :port

    sig do
      params(port: Integer, host: String, config: Config, on_crash: T.nilable(T.proc.void)).void
    end
    def initialize(port: 0, host: '127.0.0.1', config: Config.new, on_crash: nil)
      @config = config
      @on_crash = on_crash
      @mutex = Mutex.new
      @server = T.let(TCPServer.new(host, port), TCPServer)
      @port = T.let(@server.addr[1], Integer)
      @clients = T.let([], T::Array[BasicSocket])
      @threads = T.let([], T::Array[Thread])
      @stored = T.let({}, T::Hash[String, String])
      @requests = T.let([], T::Array[Request])
      @stats = T.let({}, T::Hash[String, Integer])
      @running = true
      @drops_left = T.let(Integer(config['drop_next']), Integer)
      @webhook_ids = T.let({}, T::Hash[String, String])
    end

    sig { returns(T.self_type) }
    def start
      @acceptor = T.let(Thread.new { accept_loop }, T.nilable(Thread))
      self
    end

    # Blocks until the server stops; for bin/fake-riskgate.
    sig { void }
    def join
      @acceptor&.join
    end

    sig { params(config: Config).void }
    def configure(config)
      @mutex.synchronize do
        @config = config
        @drops_left = Integer(config['drop_next'])
      end
    end

    sig { returns(T::Hash[String, Integer]) }
    def stats
      @mutex.synchronize { @stats.dup }
    end

    sig { returns(T::Array[Request]) }
    def requests
      @mutex.synchronize { @requests.dup }
    end

    # What arrived at POST /v1/webhooks/clearinghouse: accepted events by type (each
    # event id once), redeliveries of an id already seen, and rejected requests.
    sig { returns(T::Hash[String, T.untyped]) }
    def webhooks
      @mutex.synchronize do
        { 'accepted' => @webhook_ids.length, 'by_type' => @webhook_ids.values.tally.sort.to_h,
          'duplicates' => @stats.fetch('webhook_duplicates', 0), 'rejected' => @stats.fetch('webhooks_rejected', 0) }
      end
    end

    # The assessment id stored under an Idempotency-Key, for tests.
    sig { params(key: String).returns(T.nilable(String)) }
    def assessment_id_for(key)
      stored = @mutex.synchronize { @stored[key] }
      stored && JSON.parse(stored)['assessment_id']
    end

    # Closes the listener and every open connection at once, the way a process
    # death looks from the client's side.
    sig { void }
    def stop
      @running = false
      @acceptor&.kill
      clients, threads = @mutex.synchronize { [@clients.dup, @threads.dup] }
      @server.close unless @server.closed?
      clients.each { |c| c.close unless c.closed? }
      threads.each { |t| t.kill unless t == Thread.current }
    end

    private

    sig { void }
    def accept_loop
      while @running
        client = @server.accept
        client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        @mutex.synchronize do
          bump('connections_opened')
          @clients << client
          @threads << Thread.new(client) { |c| serve(c) }
        end
      end
    rescue IOError, SystemCallError
      nil
    end

    sig { params(client: TCPSocket).void }
    def serve(client)
      served = 0
      loop do
        request = read_request(client)
        break unless request

        served += 1
        break unless dispatch(client, request)

        close_after = @mutex.synchronize { @config['close_after'] }
        break if close_after.positive? && served >= close_after
      end
    rescue IOError, SystemCallError
      nil
    ensure
      client.close unless client.closed?
      @mutex.synchronize { @clients.delete(client) }
    end

    sig { params(socket: TCPSocket).returns(T.nilable(Request)) }
    def read_request(socket)
      line = socket.gets("\r\n")
      return nil if line.nil?

      method, path = line.split
      headers = {}
      while (header = socket.gets("\r\n")) && header != "\r\n"
        name, value = header.chomp.split(':', 2)
        headers[name.to_s.downcase] = value.to_s.strip
      end
      body = socket.read(Integer(headers.fetch('content-length', '0'))).to_s
      Request.new(verb: method, path: path, headers: headers, body: body)
    end

    # Returns false when the connection must not be used again.
    sig { params(socket: TCPSocket, request: Request).returns(T::Boolean) }
    def dispatch(socket, request)
      @mutex.synchronize do
        bump('requests')
        @requests << request
        @requests.shift if @requests.length > 1000
      end
      case [request.verb, request.path]
      when %w[POST /v1/assess] then assess(socket, request)
      when %w[POST /v1/webhooks/clearinghouse] then webhook(socket, request)
      when %w[GET /admin/webhooks] then respond(socket, 200, JSON.generate(webhooks))
      when %w[GET /health] then respond(socket, 200, '{"ok":true}')
      when %w[GET /admin/config] then respond(socket, 200, JSON.generate(@mutex.synchronize { @config.values }))
      when %w[GET /admin/stats] then respond(socket, 200, JSON.generate(stats))
      when %w[POST /admin/config] then admin_config(socket, request)
      else respond(socket, 404, error_body('no_route'))
      end
    end

    sig { params(socket: TCPSocket, request: Request).returns(T::Boolean) }
    def admin_config(socket, request)
      configure(Config.new(JSON.parse(request.body)))
      respond(socket, 200, JSON.generate(@mutex.synchronize { @config.values }))
    rescue JSON::ParserError, ArgumentError, TypeError => e
      respond(socket, 400, error_body('invalid_config', e.message))
    end

    sig { params(socket: TCPSocket, request: Request).returns(T::Boolean) }
    def assess(socket, request)
      key = request.headers['idempotency-key'].to_s
      config, stored = @mutex.synchronize { [@config, @stored[key]] }
      return crash! if config['crash']
      return CLOSE if take_drop
      return respond(socket, 200, stored, 'Idempotent-Replayed' => 'true').tap { count('replays') } if stored
      return hang(socket) if config['hang'] || config.draw < Float(config['hang_rate'])

      sleep(config.latency_seconds)
      return respond(socket, Integer(config['error_status']), error_body('injected')) if
        config.draw < Float(config['error_rate'])
      return respond(socket, 200, '{"decision": "allow", "risk_sc') if config.draw < Float(config['malformed_rate'])

      respond(socket, 200, fresh_assessment(config, request, key))
    rescue JSON::ParserError, ArgumentError, TypeError, KeyError => e
      respond(socket, 400, error_body('invalid_request', e.message))
    end

    # Verifies Clearinghouse-Signature (t=<unix>,v1=<hex HMAC-SHA256(secret, "t.body")>)
    # the way RiskGate does, against the wall clock, and dedupes by event id.
    sig { params(socket: TCPSocket, request: Request).returns(T::Boolean) }
    def webhook(socket, request)
      config = @mutex.synchronize { @config }
      unless signed?(request, config)
        count('webhooks_rejected')
        return respond(socket, 400, error_body('invalid_signature'))
      end

      event = JSON.parse(request.body)
      id = event.fetch('id')
      type = event.fetch('type')
      @mutex.synchronize do
        next bump('webhook_duplicates') if @webhook_ids.key?(id)

        @webhook_ids[id] = type
      end
      respond(socket, 200, '{"status":"ok"}')
    rescue JSON::ParserError, KeyError, TypeError
      count('webhooks_rejected')
      respond(socket, 400, error_body('invalid_event'))
    end

    sig { params(request: Request, config: Config).returns(T::Boolean) }
    def signed?(request, config)
      parts = request.headers['clearinghouse-signature'].to_s.split(',').map { |p| p.split('=', 2) }
      timestamp = parts.find { |k, _| k == 't' }&.last
      return false unless timestamp&.match?(/\A\d+\z/)
      # RiskGate checks the timestamp against its own wall clock, and so does the fake.
      return false if (Time.now.to_i - Integer(timestamp, 10)).abs > Integer(config['webhook_tolerance'])

      given = parts.filter_map { |k, v| v if k == 'v1' }
      Array(config['webhook_secrets']).any? do |secret|
        expected = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{request.body}")
        given.any? { |v| v.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(v, expected) }
      end
    end

    sig { params(config: Config, request: Request, key: String).returns(String) }
    def fresh_assessment(config, request, key)
      payload = JSON.parse(request.body)
      unless payload.is_a?(Hash) && payload['payment_id'].is_a?(String) && payload['amount'].is_a?(Integer)
        raise ArgumentError, 'payment_id and an integer amount are required'
      end

      body = JSON.generate(config.decide(payload).merge('assessment_id' => next_id))
      @mutex.synchronize do
        bump('assessments')
        @stored[key] = body unless key.empty?
      end
      body
    end

    sig { returns(String) }
    def next_id
      @mutex.synchronize { format('asm_%<n>08d', n: bump('ids')) }
    end

    sig { params(name: String).void }
    def count(name)
      @mutex.synchronize { bump(name) }
    end

    # Callers hold the mutex.
    sig { params(name: String).returns(Integer) }
    def bump(name)
      @stats[name] = @stats.fetch(name, 0) + 1
    end

    sig { returns(T::Boolean) }
    def take_drop
      @mutex.synchronize do
        next false unless @drops_left.positive?

        @drops_left -= 1
        bump('drops')
        true
      end
    end

    # Holds the connection open and says nothing until the client gives up.
    sig { params(socket: TCPSocket).returns(T::Boolean) }
    def hang(socket)
      count('hangs')
      socket.wait_readable
      CLOSE
    end

    sig { returns(T::Boolean) }
    def crash!
      count('crashes')
      if @on_crash
        @on_crash.call
      else
        Thread.new { stop }
      end
      CLOSE
    end

    # RiskGate's error shape: {"error": {"code", "message"}}.
    sig { params(code: String, message: String).returns(String) }
    def error_body(code, message = code)
      JSON.generate('error' => { 'code' => code, 'message' => message })
    end

    sig do
      params(socket: TCPSocket, status: Integer, body: String, headers: T::Hash[String, String]).returns(T::Boolean)
    end
    def respond(socket, status, body, headers = {})
      head = ["HTTP/1.1 #{status} #{status == 200 ? 'OK' : 'X'}", 'Content-Type: application/json',
              "Content-Length: #{body.bytesize}"]
      headers.each { |k, v| head << "#{k}: #{v}" }
      socket.write("#{head.join("\r\n")}\r\n\r\n#{body}")
      KEEP_OPEN
    end
  end
end
