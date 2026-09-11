# typed: false
# frozen_string_literal: true

DBHelper.clean_tables('idem_spec_log')

# A flow with nothing to do with payments, for testing the runner on its own. Its
# phases write to idem_spec_log (a table only the specs have), so a test can see
# exactly which phases ran and how many times.
#
#   started -> written -> called -> finished
module ToyFlow
  class Input < T::Struct
    const :label, String
  end

  # A 4xx: the same request fails the same way, so it is stored.
  class FinalError < StandardError; end

  # Anything else: not stored, the lease is given back.
  class TransientError < StandardError; end

  class Flow < Clearinghouse::Idempotency::Flow
    attr_reader :foreign_calls, :resumed_seen, :released
    attr_accessor :fail_in, :before_atomic

    def initialize
      super
      @foreign_calls = []
      @resumed_seen = []
      @released = []
      @fail_in = {}
      @mutex = Mutex.new
    end

    def name = 'spec.toy'

    def load_input(hash) = Input.from_hash(hash)

    def phases
      i = Clearinghouse::Idempotency
      [
        i::Phase.new(from: i::STARTED, to: 'written', atomic: lambda { |run, db, _|
          step(run, db, 'written')
          run.state['written_at'] = run.input.label
          nil
        }),
        i::Phase.new(from: 'written', to: 'called',
                     foreign: lambda { |run|
                       @mutex.synchronize do
                         @foreign_calls << run.input.label
                         @resumed_seen << run.resumed
                       end
                       "reply-#{run.input.label}"
                     },
                     atomic: lambda { |run, db, reply|
                       step(run, db, 'called', reply)
                       nil
                     }),
        i::Phase.new(from: 'called', to: i::FINISHED, atomic: lambda { |run, db, _|
          step(run, db, 'finished')
          run.render({ 'label' => run.input.label, 'state' => run.state })
        })
      ]
    end

    def release(run, _db)
      @mutex.synchronize { @released << run.key_id }
    end

    private

    def step(run, db, name, detail = nil)
      before_atomic&.call(name, run)
      error = fail_in[name]
      raise error if error

      db[:idem_spec_log].insert(key_id: run.key_id, step: name, detail: detail)
    end
  end

  class Renderer
    include Clearinghouse::Idempotency::Renderer

    def render(object, status: 200)
      Clearinghouse::Idempotency::Response.new(status: status, body: JSON.generate(object),
                                               headers: { 'x-rendered' => 'yes' })
    end

    def error_response(error)
      return nil unless error.is_a?(FinalError)

      Clearinghouse::Idempotency::Response.new(status: 400, body: JSON.generate('error' => error.message))
    end

    def options = { 'style' => 'toy' }
  end

  def self.create_table!
    DBHelper.owner.run(<<~SQL)
      CREATE TABLE IF NOT EXISTS idem_spec_log (
        id bigserial PRIMARY KEY, key_id bigint NOT NULL, step text NOT NULL, detail text
      );
      GRANT SELECT, INSERT, DELETE ON idem_spec_log TO clearinghouse_app;
    SQL
  end
end

RSpec.shared_context 'with the toy flow' do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:flow) { ToyFlow::Flow.new }
  let(:registry) { Clearinghouse::Idempotency::Registry.new([flow]) }
  let(:renderer) { ToyFlow::Renderer.new }
  let(:runner) { Clearinghouse::Idempotency::Runner.new(db: app_db, clock: clock, lock_timeout: 60) }
  let(:merchant_id) do
    Clearinghouse::Merchants.create(app_db, clock: clock, name: 'Toy', api_version: '2026-09-01').first.id
  end

  before(:context) { ToyFlow.create_table! }

  def toy_request(key: 'k1', params: { 'label' => 'a' }, request_id: Clearinghouse::Ids.generate('req'))
    Clearinghouse::Idempotency::Runner::Request.new(merchant_id: merchant_id, key: key, http_method: 'POST',
                                                    path: '/v1/toys', params: params, request_id: request_id)
  end

  def run_toy(key: 'k1', label: 'a', runner: self.runner, request_id: Clearinghouse::Ids.generate('req'))
    runner.call(flow: flow, input: ToyFlow::Input.new(label: label),
                request: toy_request(key: key, params: { 'label' => label }, request_id: request_id),
                context: nil, renderer: renderer)
  end

  def log_steps
    app_db[:idem_spec_log].order(:id).select_map(:step)
  end

  def key_row(key = 'k1')
    app_db[:idempotency_keys].where(key: key).first
  end
end
