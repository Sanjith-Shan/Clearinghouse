# typed: false
# frozen_string_literal: true

require 'tmpdir'
require_relative '../../sim/experiments/crash_matrix'

# Two cases of experiment 2 end to end, against real processes: bin/sim, the
# fake RiskGate, and the API on Puma, killed by the crash hook and restarted. The
# full matrix is bin/crash-matrix; this keeps the harness itself honest in CI.
#
# - capture_recorded:before_commit: the acquirer captured, the transaction that
#   records it died. The resume must ask the acquirer and record that capture.
# - the ambiguous variant: after the crash, the simulator drops the answer to the
#   authorization the resume sends; the next resume must ask, not resend.
RSpec.describe 'Experiment 2 crash matrix, end to end' do
  let(:cm) { Experiments::CrashMatrix }

  it 'crashes the server, recovers by retrying, and checks the outcome against an uninterrupted control' do
    names = %w[payment_intent.capture:capture_recorded:before_commit
               payment_intent.confirm:authorization_requested+acquirer_drop]
    cases = cm.plan(Clearinghouse::Payments::Flows.registry).select { |c| names.include?(c.name) }
    report = Dir.mktmpdir('crash-matrix') do |dir|
      settings = cm::Settings.new(db_name: ENV.fetch('CLEARINGHOUSE_DB', 'clearinghouse_test'), log_dir: dir)
      cm::Session.new(settings: settings, cases: cases, full: false).run(command: 'spec')
    end

    expect(report['cases'].map { |c| c['name'] }).to eq(names)
    failures = report['cases'].reject { |c| c['passed'] }
                              .map { |c| [c['name'], c['error'], c['checks'].reject { |ch| ch['ok'] }] }
    expect(failures).to eq([])

    capture, ambiguous = report['cases']
    expect(capture['checks'].map { |c| c['name'] })
      .to include('crashed', 'key_at_crash', 'ledger_invariants', 'acquirer_equals_ledger', 'one_event_per_change',
                  'same_response_as_control', 'retry_replays_it', 'same_outcome_as_control')
    # The capture reached the acquirer before the crash; the resume only asked.
    expect(capture['acquirer_exchanges']['crashed_request'].grep(%r{POST /capture}).length).to eq(1)
    expect(capture['acquirer_exchanges']['retry_1'])
      .to contain_exactly(%r{\AGET /operations/pi_\w+%3Acapture%3A1 -> 200\z})
    expect(ambiguous['recovery']).to eq(['retry 1: 503 acquirer_unavailable', 'retry 2: 200 succeeded'])
    expect(report['headline']).to start_with('PARTIAL RUN')
  end
end
