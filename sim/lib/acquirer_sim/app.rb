# typed: true
# frozen_string_literal: true

require 'sinatra/base'

module AcquirerSim
  # The HTTP face of the simulator. It parses headers and bodies, asks the Simulator
  # for an outcome, and renders it. No business rule lives here.
  class App < Sinatra::Base
    extend T::Sig

    set :show_exceptions, false
    set :raise_errors, false
    set :dump_errors, false
    set :logging, false
    set :host_authorization, { permitted_hosts: [] }
    # Rack::Protection's path cleaning turns %2F into a slash, which would make a key
    # containing "/" unreachable by the status query. The simulator serves no browser.
    set :protection, false

    sig { returns(Simulator) }
    attr_reader :simulator

    sig { params(app: T.untyped, simulator: Simulator).void }
    def initialize(app = nil, simulator: Simulator.new)
      super(app)
      @simulator = simulator
    end

    before do
      T.bind(self, App)
      content_type :json
    end

    get '/health' do
      T.bind(self, App)
      json('status' => 'ok')
    end

    Simulator::MUTATIONS.each do |type|
      post "/#{type}" do
        T.bind(self, App)
        mutate(type)
      end
    end

    get '/operations/:key' do
      T.bind(self, App)
      next unavailable if misbehave.unavailable

      operation = simulator.operation(params.fetch('key'))
      operation ? json(operation.to_h) : error_response(RequestError.new(404, 'not_found', 'no operation for that key'))
    end

    # Everything the simulator has done, for experiments that count charges from the
    # acquirer's side rather than trusting Clearinghouse's own records.
    get '/admin/operations' do
      T.bind(self, App)
      reference = params['reference']
      operations = simulator.operations.select { |op| reference.nil? || op.reference == reference }
      authorizations = simulator.authorizations.select { |a| reference.nil? || a.reference == reference }
      json('operations' => operations.map(&:to_h), 'authorizations' => authorizations.map(&:to_h),
           'charges_by_reference' => Simulator.charges_by_reference(authorizations))
    end

    get '/admin/config' do
      T.bind(self, App)
      json(simulator.config.to_h)
    end

    post '/admin/config' do
      T.bind(self, App)
      json(simulator.configure(raw_body).to_h)
    rescue RequestError => e
      error_response(e)
    end

    post '/admin/reset' do
      T.bind(self, App)
      simulator.reset!
      json('reset' => true)
    end

    # A catch-all route rather than a `not_found` block: Sinatra runs that block for
    # any 404, including the status query's own "no operation under this key", and
    # the two must stay distinguishable (Clearinghouse's client treats only the
    # latter as NotFound).
    %w[GET POST PUT PATCH DELETE].each do |verb|
      T.unsafe(self).send(verb.downcase, '*') do
        T.bind(self, App)
        status 404
        json('error' => 'no_route', 'message' => "no route for #{request.request_method} #{request.path_info}")
      end
    end

    error do
      T.bind(self, App)
      failure = env['sinatra.error']
      json('error' => 'internal_error', 'message' => failure.class.name)
    end

    private

    # A mutating request. The order matters and is the contract Clearinghouse's client
    # relies on: a 503 is decided and returned before anything is committed, so it
    # always means "not processed"; a dropped connection happens only after the
    # commit, so it always means "maybe processed, ask me".
    sig { params(type: String).returns(T.nilable(String)) }
    def mutate(type)
      decision = misbehave
      return unavailable if decision.unavailable

      sim_time = Params.sim_time(request.env['HTTP_SIM_TIME'])
      key = Params.idempotency_key(request.env['HTTP_IDEMPOTENCY_KEY'])
      body = raw_body
      result = simulator.submit(type, key, body, sim_time)
      return drop_connection! if !result.replayed && (result.drop_connection || decision.drop_after_commit)

      headers 'Idempotent-Replayed' => result.replayed.to_s
      json(result.operation.to_h)
    rescue RequestError => e
      error_response(e)
    end

    # Draws this request's misbehaviour and serves its latency. The sleep is real
    # time on purpose: it is what makes a client's read timeout fire.
    sig { returns(Traffic::Decision) }
    def misbehave
      decision = simulator.traffic_decision
      sleep(decision.latency_seconds) if decision.latency_seconds.positive?
      decision
    end

    sig { returns(String) }
    def unavailable
      status 503
      json('error' => 'service_unavailable', 'message' => 'simulated outage; nothing was processed')
    end

    # Takes the socket from the server (a Rack full hijack) and closes it without
    # writing a byte, so the client sees the connection end mid-request (EOFError or
    # a reset), exactly as it would if the acquirer crashed after committing. A 500
    # would not do: a client can tell a 500 apart, and the point is that it cannot.
    sig { returns(NilClass) }
    def drop_connection!
      hijack = request.env['rack.hijack']
      raise 'this server does not support Rack full hijack; run the simulator on Puma' unless hijack

      hijack.call.close
      nil
    end

    # The body as sent, whatever Content-Type claims. Sinatra parses form-encoded
    # bodies into params before the route runs, which consumes the input, so rewind.
    sig { returns(T::Hash[String, T.untyped]) }
    def raw_body
      input = request.body
      input.rewind if input.respond_to?(:rewind)
      Params.parse_json(input.read.to_s)
    end

    sig { params(failure: RequestError).returns(String) }
    def error_response(failure)
      status failure.status
      json(failure.to_h)
    end

    sig { params(value: T.untyped).returns(String) }
    def json(value)
      JSON.generate(value)
    end
  end
end
