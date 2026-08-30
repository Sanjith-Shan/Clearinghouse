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

    post '/admin/reset' do
      T.bind(self, App)
      simulator.reset!
      json('reset' => true)
    end

    not_found do
      T.bind(self, App)
      json('error' => 'not_found', 'message' => "no route for #{request.request_method} #{request.path_info}")
    end

    error do
      T.bind(self, App)
      failure = env['sinatra.error']
      json('error' => 'internal_error', 'message' => failure.class.name)
    end

    private

    sig { params(type: String).returns(String) }
    def mutate(type)
      sim_time = Params.sim_time(request.env['HTTP_SIM_TIME'])
      key = Params.idempotency_key(request.env['HTTP_IDEMPOTENCY_KEY'])
      body = Params.parse_json(request.body.read)
      result = simulator.submit(type, key, body, sim_time)
      headers 'Idempotent-Replayed' => result.replayed.to_s
      json(result.operation.to_h)
    rescue RequestError => e
      error_response(e)
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
