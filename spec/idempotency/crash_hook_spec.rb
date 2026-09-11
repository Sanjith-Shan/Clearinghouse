# typed: false
# frozen_string_literal: true

# Stands in for exit! in process: an Exception, not a StandardError, so no rescue
# in the runner sees it, exactly like a process that simply stops.
class SimulatedCrash < Exception; end # rubocop:disable Lint/InheritException

RSpec.describe Clearinghouse::Idempotency::CrashHook, :db do
  include_context 'with the toy flow'

  let(:idem) { Clearinghouse::Idempotency }

  describe 'arming' do
    it 'is disarmed unless CLEARINGHOUSE_ENV is test or experiment, whatever CLEARINGHOUSE_CRASH_AT says' do
      at = 'spec.toy:written'
      expect(described_class.from_env('CLEARINGHOUSE_CRASH_AT' => at)).to equal(described_class::DISARMED)
      expect(described_class.from_env('CLEARINGHOUSE_CRASH_AT' => at, 'CLEARINGHOUSE_ENV' => 'production'))
        .to equal(described_class::DISARMED)
      expect(described_class.from_env('CLEARINGHOUSE_ENV' => 'test')).to equal(described_class::DISARMED)
      armed = described_class.from_env('CLEARINGHOUSE_CRASH_AT' => at, 'CLEARINGHOUSE_ENV' => 'experiment')
      expect(armed.target).to eq(at)
    end

    it 'cannot be built outside test or experiment even directly' do
      expect { described_class::Armed.new('x:y', env: { 'CLEARINGHOUSE_ENV' => 'production' }) }
        .to raise_error(described_class::NotAllowedError)
    end

    it 'fires once, only at its own point and moment' do
      fired = []
      hook = described_class::Armed.new('f:p:before_commit', env: { 'CLEARINGHOUSE_ENV' => 'test' },
                                                             action: -> { fired << :boom })
      hook.reached('f', 'p', :after_commit)
      hook.reached('g', 'p', :before_commit)
      2.times { hook.reached('f', 'p', :before_commit) }
      expect(fired).to eq([:boom])
    end

    it 'is what the API wires from the environment' do
      expect(Clearinghouse::Api::Dependencies.new(db: app_db, clock: clock).crash_hook)
        .to equal(described_class::DISARMED)
    end
  end

  # Every crash point of the toy flow, generated from the registry: crash there,
  # then let a fresh runner (the "restarted process") resume the key once the
  # lease has run out. The result must be exactly what an uninterrupted run
  # returns, and every phase's work must have happened exactly once.
  describe 'recovery at every point' do
    let(:control) do
      run_toy(key: 'control').response
    end

    Clearinghouse::Idempotency::Registry.new([ToyFlow::Flow.new]).crash_points.each do |point|
      it "recovers from a crash at #{point}" do
        expected_body = JSON.parse(control.body)
        app_db[:idem_spec_log].delete
        hook = described_class::Armed.new(point.to_s, env: { 'CLEARINGHOUSE_ENV' => 'test' },
                                                      action: -> { raise SimulatedCrash })
        crashing = idem::Runner.new(db: app_db, clock: clock, lock_timeout: 60, crash_hook: hook)
        expect { run_toy(runner: crashing) }.to raise_error(SimulatedCrash)

        row = key_row
        if row.nil?
          # Crashed before the key's first commit: nothing happened, the retry starts afresh.
          expect([point.point, point.moment]).to eq(['started', :before_commit])
        else
          clock.advance(61)
          expect(runner.resume(registry: registry, id: row[:id], context: nil, renderer: renderer).response.status)
            .to eq(200)
        end
        again = run_toy
        expect(JSON.parse(again.response.body)).to eq(expected_body)
        expect(log_steps.tally).to eq('written' => 1, 'called' => 1, 'finished' => 1)
      end
    end
  end
end
