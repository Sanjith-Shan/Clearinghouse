# typed: false
# frozen_string_literal: true

require_relative '../../lib/clearinghouse/experiments/reconciliation_month'

RSpec.describe Clearinghouse::Experiments::ReconciliationMonth do
  let(:month) { described_class }

  describe described_class::Scorer do
    def manifest(date, discrepancies, carried = [])
      { 'date' => date, 'discrepancies' => discrepancies, 'carried_over' => carried }
    end

    def line(type, ref, operation, line_type: 'capture')
      { 'type' => type, 'acquirer_reference' => ref, 'operation_id' => operation, 'line_type' => line_type }
    end

    def exception(id, reason, ref, operation, line_type: 'capture')
      { id: id, reason: reason, acquirer_reference: ref, operation_id: operation, line_type: line_type, flow_id: 'pi_1',
        detail: 'x' }
    end

    it 'counts detections by type, other-type reports, misses and false exceptions' do
      manifests = [manifest('2026-01-03', [line('duplicate', 'acq_1', 'op_1'), line('fee_mismatch', 'acq_2', 'op_2'),
                                           line('missing', 'acq_3', 'op_3'), line('late', 'acq_4', 'op_4')])]
      exceptions = [exception('rex_1', 'duplicate', 'acq_1', 'op_1'),
                    exception('rex_2', 'amount_mismatch', 'acq_2', 'op_2'),
                    exception('rex_3', 'missing', 'acq_3', nil), # a missing capture has no operation id
                    exception('rex_9', 'unknown_payment', 'acq_9', 'op_9')]
      score = described_class.new(manifests: manifests, exceptions: exceptions).score

      expect(score['injected']).to include('duplicate' => 1, 'fee_mismatch' => 1, 'missing' => 1, 'late' => 1)
      expect(score['detected']).to include('duplicate' => 1, 'missing' => 1, 'fee_mismatch' => 0, 'late' => 0)
      expect(score['detected_as_another_type'])
        .to eq([{ 'injected' => 'fee_mismatch', 'reported' => 'amount_mismatch' }])
      expect(score['undetected'].map { |u| u['type'] }).to eq(['late'])
      expect(score['false_exceptions'].map { |x| x['id'] }).to eq(['rex_9'])
    end

    it 'matches exact types first when one line carries two discrepancies' do
      manifests = [manifest('2026-01-03', [line('late', 'acq_1', 'op_1')]),
                   manifest('2026-01-04', [line('amount_mismatch', 'acq_1', 'op_1')])]
      exceptions = [exception('rex_1', 'amount_mismatch', 'acq_1', 'op_1'),
                    exception('rex_2', 'late', 'acq_1', 'op_1')]
      score = described_class.new(manifests: manifests, exceptions: exceptions).score
      expect(score['detected']).to include('late' => 1, 'amount_mismatch' => 1)
      expect(score['false_exceptions']).to be_empty
    end

    it 'counts a line deferred twice as late once, and the missing report it caused on the way as expected' do
      manifests = [manifest('2026-01-05', [line('late', 'acq_1', 'op_1', line_type: 'refund')]),
                   manifest('2026-01-06', [line('late', 'acq_1', 'op_1', line_type: 'refund')])]
      exceptions = [exception('rex_1', 'missing', 'acq_1', 'op_1', line_type: 'refund')
        .merge(resolution_action: 'auto'),
                    exception('rex_2', 'late', 'acq_1', 'op_1', line_type: 'refund')]
      score = described_class.new(manifests: manifests, exceptions: exceptions).score
      expect(score['detected']).to include('late' => 2)
      expect(score).to include('false_exceptions' => [], 'missing_then_arrived' => 1, 'detected_as_another_type' => [])
    end

    it 'does not count the lateness of a line that was then dropped as a miss' do
      manifests = [manifest('2026-01-05', [line('late', 'acq_1', 'op_1')]),
                   manifest('2026-01-06', [line('missing', 'acq_1', 'op_1')])]
      score = described_class.new(manifests: manifests,
                                  exceptions: [exception('rex_1', 'missing', 'acq_1', nil)]).score
      expect(score['detected']).to include('missing' => 1, 'late' => 0)
      expect(score['not_observable'].map { |d| d['type'] }).to eq(['late'])
      expect(score.values_at('undetected', 'false_exceptions')).to eq([[], []])
    end

    it 'counts carried-over lines and whether any was called late' do
      carried = [{ 'acquirer_reference' => 'acq_5', 'operation_id' => 'op_5', 'line_type' => 'capture',
                   'injected_late' => false },
                 { 'acquirer_reference' => 'acq_6', 'operation_id' => 'op_6', 'line_type' => 'capture',
                   'injected_late' => true }]
      score = described_class.new(manifests: [manifest('2026-01-05', [], carried)],
                                  exceptions: [exception('rex_1', 'late', 'acq_5', 'op_5')]).score
      expect(score).to include('carried_over_not_injected' => 1, 'carried_over_flagged_late' => 1)
    end
  end

  it 'refuses to empty a database that is not for tests or experiments' do
    owner = Sequel.mock(host: 'postgres', database: 'clearinghouse_dev')
    expect { month.reset!(owner) }.to raise_error(ArgumentError, /not a test or experiment database/)
  end

  # A small month end to end: the acquirer simulator and the API on real ports, traffic
  # through the Ruby client library, and every injected discrepancy scored.
  describe 'a small month through the API', :db do
    let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 1, 1)) }
    let(:simulator) { AcquirerSim::Simulator.new.tap { |s| s.configure('seed' => 7) } }
    let(:sim) { Clearinghouse::Experiments::LocalServer.new(AcquirerSim::App.new(simulator: simulator)) }
    let(:acquirer) { Clearinghouse::Acquirer::Client.new(clock: clock, base_url: sim.url) }
    let(:api) do
      deps = Clearinghouse::Api::Dependencies.new(db: app_db, clock: clock, acquirer: acquirer, admin_token: 'exp5')
      Clearinghouse::Experiments::LocalServer.new(Clearinghouse::Api.rack_app(deps))
    end
    let(:config) do
      month::Config.new(seed: 7, payments: 40, discrepancies: 9, merchants: 2, days: 6, tail_days: 12,
                        dispute_rate: 0.1, refund_rate: 0.3)
    end

    after do
      api.stop
      sim.stop
    end

    it 'detects every injected discrepancy with no false exceptions and explains every flow once resolved' do
      driver = month::ApiDriver.new(api_url: api.url, admin_token: 'exp5')
      result = month::Runner.new(config: config, db: app_db, clock: clock, sim_url: sim.url, driver: driver,
                                 acquirer: acquirer).run
      score = result.fetch('score')

      expect(score['injected'].values.sum).to eq(9)
      unobservable = score['not_observable'].map { |d| d['type'] }.tally
      expect(score['detected'].to_h { |type, n| [type, n + unobservable.fetch(type, 0)] }).to eq(score['injected'])
      expect(score.values_at('detected_as_another_type', 'undetected', 'false_exceptions')).to eq([[], [], []])
      expect(score['carried_over_flagged_late']).to eq(0)
      expect(result['explainability_after_resolving'].map { |e| e['share'] }).to all(eq(1.0))
      expect(result.values_at('invariant_violations', 'balance_drifts')).to eq([{ 'before' => 0, 'after' => 0 }, 0])
      expect(result['workload']).to include('captured' => be_positive, 'lagging_captures' => be_positive)
    end
  end
end
