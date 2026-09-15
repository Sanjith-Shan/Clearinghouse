# typed: false
# frozen_string_literal: true

require_relative '../../sim/experiments/storm'
require_relative '../../lib/clearinghouse/experiments/storm_baselines'

DBHelper.clean_tables(Clearinghouse::Experiments::StormBaselines::NAIVE_TABLE)

# The acquirer simulator and the API with the two baselines mounted, each on Puma in
# this process on an ephemeral port: the same network path bin/storm uses, started once.
module StormSpec
  BASELINES = Clearinghouse::Experiments::StormBaselines
  EXPERIMENT_ENV = { 'CLEARINGHOUSE_ENV' => 'experiment' }.freeze

  def self.sim
    @sim ||= SimServer.start
  end

  def self.api
    @api ||= begin
      BASELINES.ensure_table!(DBHelper.owner)
      clock = Clearinghouse::Clock::Real.new
      deps = Clearinghouse::Api::Dependencies.new(
        db: DBHelper.app, clock: clock, acquirer: Clearinghouse::Acquirer::Client.new(clock: clock, base_url: sim.url)
      )
      server = Puma::Server.new(BASELINES.rack_app(deps, env: EXPERIMENT_ENV), nil,
                                min_threads: 1, max_threads: 12, log_writer: Puma::LogWriter.null)
      server.add_tcp_listener('127.0.0.1', 0)
      server.run
      server
    end
  end

  def self.stop
    @api&.stop(true)
    @sim&.stop
  end

  def self.storm(impl, max_retries:)
    plan = Experiments::Storm::Plan.new(intents: 2, concurrency: 4, drop_rate: 1.0, seed: 7, parallel: 2,
                                        max_retries: max_retries)
    Experiments::Storm::Runner.new(api_url: "http://127.0.0.1:#{api.connected_ports.first}", sim_url: sim.url,
                                   db: DBHelper.app, plan: plan, log: nil).run(impl)
  end
end

RSpec.configure do |config|
  config.after(:suite) { StormSpec.stop }
end

RSpec.describe 'Experiment 1: the retry storm' do
  # Two intents, four clients each, and every fresh acquirer commit drops its response
  # (drop rate 1.0). That makes the outcome deterministic: every intent's first
  # authorization is charged and its answer lost.
  context 'when the acquirer loses every first answer' do
    before { DBHelper.clean! }

    it 'charges each intent exactly once under Clearinghouse, in the acquirer and in the ledger' do
      result = StormSpec.storm('clearinghouse', max_retries: 10)

      expect(result.values_at('double_charges', 'charged_not_recorded', 'stuck_processing')).to eq([0, 0, 0])
      expect(result.fetch('acquirer_captures_per_intent')).to eq('1' => 2)
      expect(result.fetch('ledger_captures_per_intent')).to eq('1' => 2)
      expect(result.fetch('final_status')).to eq('succeeded' => 2)
      expect(result.fetch('ledger_invariants')).to eq('hold')
    end

    it 'gives every client of an intent the same bytes under Clearinghouse, and the truth' do
      result = StormSpec.storm('clearinghouse', max_retries: 10)

      expect(result.fetch('answers_by_http_status')).to eq('200' => 8)
      expect(result.fetch('identical_body_rate')).to eq(1.0)
      expect(result.fetch('truthful_answer_rate')).to eq(1.0)
    end

    # Proves the harness can see a double charge at all: a counter that always said
    # zero would pass the examples above.
    it 'charges twice without idempotency: the lost approval fails the attempt and the retry pays again' do
      result = StormSpec.storm('none', max_retries: 2)

      expect(result.values_at('double_charges', 'charged_not_recorded')).to eq([2, 2])
      expect(result.fetch('identical_body_rate')).to be < 1.0
      expect(result.fetch('ledger_invariants')).to eq('hold')
    end
  end

  it 'refuses to mount the baselines outside CLEARINGHOUSE_ENV=experiment' do
    deps = Clearinghouse::Api::Dependencies.new(db: DBHelper.app, clock: Clearinghouse::Clock::Real.new)

    %w[production test].each do |env|
      expect { StormSpec::BASELINES.rack_app(deps, env: { 'CLEARINGHOUSE_ENV' => env }) }
        .to raise_error(StormSpec::BASELINES::NotAllowedError)
    end
  end

  describe 'the tally' do
    let(:paid) { '{"id":"pi_a","status":"succeeded"}' }
    let(:refused) { '{"error":{"code":"payment_intent_unexpected_state"}}' }
    let(:tally) do
      answer = ->(status, body) { Experiments::Storm::Answer.new(status: status, body: body, statuses: [503, status]) }
      Experiments::Storm.tally(
        impl: 'none', plan: Experiments::Storm::Plan.new(intents: 3, concurrency: 2, drop_rate: 0.5),
        intents: %w[pi_a pi_b pi_c],
        answers: { 'pi_a' => [answer.call(200, paid), answer.call(400, refused)],
                   'pi_b' => [answer.call(200, paid), answer.call(200, paid)],
                   'pi_c' => [answer.call(400, refused), answer.call(nil, nil)] },
        wall: 1.0, acquirer: { 'pi_a' => 2, 'pi_b' => 1, 'pi_c' => 1 }, ledger: { 'pi_a' => 1, 'pi_b' => 1 },
        rows: { 'pi_a' => ['succeeded', 2], 'pi_b' => ['succeeded', 1], 'pi_c' => ['processing', 1] },
        violations: []
      )
    end

    it 'counts double charges from the acquirer and compares them with the ledger' do
      expect(tally.values_at('double_charges', 'extra_charges', 'charged_not_recorded', 'stuck_processing'))
        .to eq([1, 1, 2, 1])
      expect(tally.fetch('acquirer_captures_per_intent')).to eq('1' => 2, '2' => 1)
      expect(tally.fetch('ledger_captures_per_intent')).to eq('0' => 1, '1' => 2)
    end

    it 'compares bodies per intent and checks each answer against the acquirer' do
      expect(tally.values_at('identical_body_intents', 'truthful_answers')).to eq([1, 3])
      expect(tally.fetch('answers_by_http_status')).to eq('200' => 3, '400' => 2, 'no_response' => 1)
      expect(tally.values_at('requests', 'http_attempts')).to eq([6, 12])
    end
  end
end
