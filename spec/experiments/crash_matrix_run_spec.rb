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

  # The retries that meet the dead request's lease. The lease is renewed at every
  # phase commit, so its 1 s runs from the crash, and whether the clean server
  # boots inside it depends on the machine's load: on a loaded run the first
  # retries answer 409 idempotency_key_in_use. That is correct (the harness's
  # recovered_without_detours allows exactly that), so the count is not asserted,
  # but those retries must not have reached the acquirer. Returns how many there
  # were and the answers after them.
  def past_the_lease(kase)
    waited = kase['recovery'].take_while { |line| line.include?('409 idempotency_key_in_use') }.length
    (1..waited).each { |i| expect(kase['acquirer_exchanges'].fetch("retry_#{i}")).to eq([]) }
    [waited, kase['recovery'].drop(waited).map { |line| line.sub(/\Aretry \d+: /, '') }]
  end

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
    expect(failures).to eq([]), -> { "failed cases (untruncated): #{failures.inspect}" }

    capture, ambiguous = report['cases']
    expect(capture['checks'].map { |c| c['name'] })
      .to include('crashed', 'key_at_crash', 'ledger_invariants', 'acquirer_equals_ledger', 'one_event_per_change',
                  'same_response_as_control', 'retry_replays_it', 'same_outcome_as_control')
    # The capture reached the acquirer before the crash; the resume only asked.
    expect(capture['acquirer_exchanges']['crashed_request'].grep(%r{POST /capture}).length).to eq(1)
    waited, answers = past_the_lease(capture)
    expect(answers).to eq(['200 succeeded'])
    expect(capture['acquirer_exchanges']["retry_#{waited + 1}"])
      .to contain_exactly(%r{\AGET /operations/pi_\w+%3Acapture%3A1 -> 200\z})
    expect(past_the_lease(ambiguous).last).to eq(['503 acquirer_unavailable', '200 succeeded'])
    expect(report['headline']).to start_with('PARTIAL RUN')
  end

  # Completer mode, with the real bin/completer --once. The ambiguous variant
  # needs two completer passes: the first authorizes and loses the answer, the
  # second asks and records it. The client only ever sees the stored answer.
  it 'recovers with the completer and the client reads the stored answer' do
    cases = cm.plan(Clearinghouse::Payments::Flows.registry, only: ['acquirer_drop'])
    report = Dir.mktmpdir('crash-matrix') do |dir|
      settings = cm::Settings.new(db_name: ENV.fetch('CLEARINGHOUSE_DB', 'clearinghouse_test'), log_dir: dir,
                                  recovery: 'completer')
      cm::Session.new(settings: settings, cases: cases, full: false).run(command: 'spec')
    end

    expect(report['cases'].length).to eq(1)
    kase = report['cases'].first
    expect([kase['error'], kase['checks'].reject { |c| c['ok'] }]).to eq([nil, []])
    expect(kase['checks'].map do |c|
      c['name']
    end).to include('completer_finished_it', 'ambiguous_answer_resolved_by_asking')
    expect(kase['recovery']).to eq(['completer pass 1: exit 0, key at authorization_requested',
                                    'completer pass 2: exit 0, key at finished',
                                    'retry after completer: 200 succeeded (replayed)'])
  end

  # One background case: a real bin/poller killed inside the transaction that
  # opens a dispute, then a clean one, then the control dispute.
  it 'crashes bin/poller inside a dispute.opened and applies it exactly once after the restart' do
    cases = cm.plan(Clearinghouse::Payments::Flows.registry, only: ['notification.dispute.opened:effects_written'])
    report = Dir.mktmpdir('crash-matrix') do |dir|
      settings = cm::Settings.new(db_name: ENV.fetch('CLEARINGHOUSE_DB', 'clearinghouse_test'), log_dir: dir)
      cm::Session.new(settings: settings, cases: cases, full: false).run(command: 'spec')
    end

    expect(report['cases'].length).to eq(1)
    kase = report['cases'].first
    expect([kase['error'], kase['checks'].reject { |c| c['ok'] }]).to eq([nil, []])
    expect(kase['checks'].map { |c| c['name'] })
      .to include('crashed', 'state_at_crash', 'poller_recovered', 'second_poll_changes_nothing', 'exactly_once',
                  'cursor_at_end', 'dispute_clearing', 'same_outcome_as_control')
    expect(kase['acquirer_exchanges']['crashed_poll']).to eq(['GET /notifications?after=0 -> 200'])
  end
end
