# typed: false
# frozen_string_literal: true

require 'puma'
require 'puma/server'
require 'rack/test'
require 'socket'
require_relative '../../sim/lib/acquirer_sim'

# Drives AcquirerSim::App in process through Rack::Test. The network paths (dropped
# connections, timeouts) are tested against a real Puma in the integration specs.
module SimHelper
  include Rack::Test::Methods

  T0 = Time.utc(2026, 3, 1, 12, 0, 0)

  def self.included(base)
    base.let(:simulator) { AcquirerSim::Simulator.new }
    base.let(:app) { AcquirerSim::App.new(simulator: simulator) }
  end

  def call(method, path, body = nil, key: nil, at: T0, headers: {})
    env = { 'CONTENT_TYPE' => 'application/json' }
    env['HTTP_SIM_TIME'] = at.utc.iso8601(6) if at
    env['HTTP_IDEMPOTENCY_KEY'] = key if key
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    payload = body.is_a?(String) ? body : (body && JSON.generate(body))
    send(method, path, payload, env)
    last_response
  end

  def post_json(path, body, key: "key-#{SecureRandom.hex(6)}", at: T0, **)
    call(:post, path, body, key: key, at: at, **)
  end

  def json_body(response = last_response)
    JSON.parse(response.body)
  end

  def authorize!(payment_method: 'pm_card_visa', amount: 10_000, currency: 'usd', capture: false,
                 reference: 'pi_1', key: "auth-#{SecureRandom.hex(6)}", at: T0)
    response = post_json('/authorize', { payment_method: payment_method, amount: amount, currency: currency,
                                         capture: capture, reference: reference }, key: key, at: at)
    raise "authorize failed: #{response.status} #{response.body}" unless response.status == 200

    json_body(response)
  end
end

# A real Puma server on an ephemeral port, in this process. The network is real (a
# TCP socket, Puma's parser, full hijack), which is what the drop and timeout tests
# need; running in-process keeps it fast and lets a test reach the simulator's state.
class SimServer
  attr_reader :simulator, :port

  def self.start(simulator = AcquirerSim::Simulator.new, app: nil)
    new(simulator, app || AcquirerSim::App.new(simulator: simulator))
  end

  def initialize(simulator, app)
    @simulator = simulator
    @server = Puma::Server.new(app, nil, min_threads: 1, max_threads: 16, log_writer: Puma::LogWriter.null)
    @server.add_tcp_listener('127.0.0.1', 0)
    @port = @server.connected_ports.first
    @server.run
  end

  def url
    "http://127.0.0.1:#{port}"
  end

  def stop
    @server.stop(true)
  end

  # A port with nothing listening, for connection-refused tests.
  def self.closed_port
    listener = TCPServer.new('127.0.0.1', 0)
    port = listener.addr[1]
    listener.close
    port
  end
end
