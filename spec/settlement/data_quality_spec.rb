# typed: false
# frozen_string_literal: true

require 'open3'

# The SLA job and the data-quality report, against the simulator. The clock starts
# on 2026-03-02 09:00, so a payment made at the start is due in the 03-04 file, and
# with one day of slack it is missing once the 03-05 file is in and it is not.
RSpec.describe Clearinghouse::Reconciliation::DataQuality, :db do
  include SettlementHelpers
  include DisputeHelpers
  include ReconcilerHelpers

  let(:detector) { Clearinghouse::Reconciliation::MissingDetector.new(db: app_db, clock: clock) }
  let(:quality) { described_class.new(db: app_db, clock: clock) }

  def day(num) = Date.new(2026, 3, num)

  def visa(amount = 10_000)
    captured_payment(amount: amount, payment_method: 'pm_card_visa')
  end

  def expect_ledger_sound
    expect(Clearinghouse::Ledger::Invariants.check(app_db)).to be_empty
    expect(Clearinghouse::Ledger::Checker.run(app_db).drifts).to be_empty
  end

  describe Clearinghouse::Reconciliation::MissingDetector do
    it 'calls a line missing only after the file a day past its due date is in, and only once' do
      pi, ref = visa
      ingest(day(4), inject: [{ type: 'missing', acquirer_reference: ref }])
      expect(detector.run).to be_empty # due today; one file of slack

      ingest(day(5))
      ids = detector.run
      expect(ids.length).to eq(1)
      expect(exceptions('missing').first)
        .to include(flow_id: pi, flow_type: 'payment', merchant_id: merchant.id, line_type: 'capture',
                    acquirer_reference: ref, expected_amount: 10_000, expected_fee: 160,
                    clearing_account: 'platform:processor_receivable', unexplained_amount: 10_000, status: 'open')
      expect(exceptions('missing').first[:detail]).to include('capture line due on 2026-03-04')
      expect(detector.run).to be_empty
      expect(exceptions.length).to eq(1)
    end

    it 'finds missing refund, dispute and dispute reversal lines' do
      pi, ref = captured_payment
      re, op = refunded(pi, 1_000)
      ingest(day(4), inject: [{ type: 'missing', acquirer_reference: ref, line_type: 'refund' }])
      clock.advance_to(Time.utc(2026, 3, 9, 10))
      poller.poll
      ingest(day(11), inject: [{ type: 'missing', acquirer_reference: ref, line_type: 'dispute' }])
      resolve_at_acquirer('won')
      poller.poll
      ingest(day(13), inject: [{ type: 'missing', acquirer_reference: ref, line_type: 'dispute_reversal' }])
      ingest(day(14))
      detector.run

      dp = the_dispute
      found = exceptions('missing').to_h { |x| [x[:line_type], x] }
      expect(found.keys).to contain_exactly('refund', 'dispute', 'dispute_reversal')
      expect(found['refund']).to include(flow_id: re, operation_id: op, expected_amount: -1_000,
                                         unexplained_amount: 1_000)
      expect(found['dispute']).to include(flow_id: dp.id, operation_id: dp.acquirer_dispute_id,
                                          expected_amount: -10_000, unexplained_amount: 10_000)
      expect(found['dispute_reversal']).to include(flow_id: dp.id, expected_amount: 10_000,
                                                   unexplained_amount: -10_000)
    end

    it 'does not call anything missing before a file is due, or for days never fetched' do
      visa
      expect(detector.run).to be_empty
      ingest(day(3))
      expect(detector.overdue).to be_empty
    end

    it 'closes a missing exception when the line turns up late, and books it once' do
      pi, ref = visa
      ingest(day(4), inject: [{ type: 'late', acquirer_reference: ref, days: 3 }])
      ingest(day(5))
      detector.run
      ingest(day(6))
      expect(exceptions('missing').first[:status]).to eq('open')

      ingest(day(7))
      missing = exceptions('missing').first
      expect(missing).to include(status: 'resolved', resolution_action: 'auto')
      expect(missing[:resolution_note]).to eq('the line arrived in the 2026-03-07 file and was booked')
      expect(exceptions('late').first).to include(flow_id: pi, status: 'resolved')
      expect(open_flows).to be_empty
      expect(balance_of('platform:cash')).to eq(10_000 - 160)
      expect_ledger_sound
    end

    it 'reverses a write-off when the written-off line arrives after all' do
      pi, ref = visa
      ingest(day(4), inject: [{ type: 'late', acquirer_reference: ref, days: 3 }])
      ingest(day(5))
      id = detector.run.first
      Clearinghouse::Reconciliation::Exceptions.resolve!(app_db, id, action: 'write_off', note: 'acquirer lost it',
                                                                     clock: clock)
      expect(open_flows).to be_empty
      expect(balance_of('platform:processing_expense')).to eq(10_000)

      ingest(day(7))
      note = exceptions('missing').first[:resolution_note]
      expect(note).to match(/\Aacquirer lost it Later the line arrived in the 2026-03-07 file and was booked; /)
      expect(note).to match(/; transaction \d+ reverses the write-off\.\z/)
      expect(open_flows).to be_empty
      expect([balance_of('platform:cash'), balance_of('platform:processing_expense')]).to eq([10_000 - 160, 160])
      # capture, funds available, write-off, its reversal, settlement
      expect(app_db[:ledger_transactions].where(flow_id: pi).count).to eq(5)
      expect_ledger_sound
    end
  end

  describe 'the report' do
    it 'is healthy when everything cleared' do
      visa
      ingest(day(4))
      report = quality.run
      expect(report).to be_healthy
      payment = report.clearing.explainability.find { |e| e.flow_type == 'payment' }
      expect(payment).to have_attributes(flows: 1, explained_flows: 1, share: 1)
      expect(Clearinghouse::Reconciliation::DataQualityPrinter.render(report)).to include('HEALTHY', '100.00%')
    end

    it 'shows what is stuck, where and for how long, and raises the missing line' do
      pi, ref = visa
      visa(5_000)
      ingest(day(4), inject: [{ type: 'missing', acquirer_reference: ref }])
      ingest(day(5))
      clock.advance_to(Time.utc(2026, 3, 6)) # three days and 15 hours after the capture; the SLA is three days
      report = quality.run

      expect(report).not_to be_healthy
      expect(report.missing_raised.length).to eq(1)
      expect(report.open_exceptions).to eq('missing' => 1)
      expect(report.clearing.past_sla.map(&:flow_id)).to eq([pi])
      text = Clearinghouse::Reconciliation::DataQualityPrinter.render(report)
      expect(text).to match(/#{pi}\s+payment\s+3d 15h\s+3d 0h\s+platform:processor_receivable 100.00 USD$/)
      expect(text).to include('33.33%',
                              'Open reconciliation exceptions: missing 1', 'Raised 1 new missing exception: rex_',
                              'NEEDS ATTENTION')
      json = Clearinghouse::Reconciliation::DataQualityPrinter.to_h(report)
      expect(json['past_sla'].first).to include('flow_id' => pi, 'unexplained' => [
                                                  { 'account' => 'platform:processor_receivable', 'currency' => 'usd',
                                                    'amount' => 10_000 }
                                                ])
    end

    it 'reports orphan clearing balances and flow types with no SLA' do
      visa
      owner_db.run("UPDATE account_balances SET balance = balance + 7 WHERE account_id =
                    (SELECT id FROM ledger_accounts WHERE code = 'platform:processor_receivable')")
      report = described_class.new(db: app_db, clock: clock, slas: {}).run(raise_missing: false)
      text = Clearinghouse::Reconciliation::DataQualityPrinter.render(report)
      expect(text).to include('Orphan clearing balances (stored balance', 'platform:processor_receivable  100.07 USD',
                              'Flow types with open flows and no SLA: payment')
      expect(Clearinghouse::Reconciliation::DataQualityPrinter.to_h(report)['orphan_balances'].first)
        .to include('stored' => 10_007, 'open_flows_total' => 10_000)
    end

    it 'lists at most `limit` overdue flows' do
      3.times { visa }
      clock.advance(4 * SettlementHelpers::DAY)
      text = Clearinghouse::Reconciliation::DataQualityPrinter.render(quality.run(raise_missing: false), limit: 2)
      expect(text).to include('Open flows past SLA: 3', '... and 1 more')
    end
  end

  describe 'bin/data-quality' do
    let(:bin) { File.expand_path('../../bin/data-quality', __dir__) }

    def run_bin(*args)
      Open3.capture3({ 'CLEARINGHOUSE_DB' => app_db.opts[:database] }, bin, *args)
    end

    it 'prints the report as of a simulated time and exits 1 when something needs attention' do
      visa
      out, _, status = run_bin('--as-of', '2026-03-10T00:00:00Z', '--no-raise', '--json')
      expect(status.exitstatus).to eq(1)
      expect(JSON.parse(out)).to include('as_of' => '2026-03-10T00:00:00Z', 'healthy' => false, 'missing_raised' => [])
    end

    it 'exits 0 when healthy and 2 on a bad command line' do
      _, _, status = run_bin('--as-of', '2026-03-10T00:00:00Z')
      expect(status.exitstatus).to eq(0)
      _, err, status = run_bin('--as-of', 'yesterday')
      expect([status.exitstatus, err]).to match([2, %r{bin/data-quality}])
    end
  end
end
