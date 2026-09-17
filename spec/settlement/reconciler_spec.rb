# typed: false
# frozen_string_literal: true

# The reconciler against the simulator's real settlement files. The clock starts on
# 2026-03-02 09:00, so a movement made at the start of a test is due in the
# 2026-03-04 file (settlement_lag_days = 2).
RSpec.describe Clearinghouse::Reconciliation::Ingestor, :db do
  include SettlementHelpers
  include DisputeHelpers
  include ReconcilerHelpers

  let(:first_day) { Date.new(2026, 3, 2) }
  let(:due_day) { Date.new(2026, 3, 4) }
  let(:next_day) { Date.new(2026, 3, 5) }

  def visa(amount = 10_000, currency: 'usd', at_clock: clock)
    captured_payment(amount: amount, currency: currency, payment_method: 'pm_card_visa', at_clock: at_clock)
  end

  def cash(currency = 'usd')
    balance_of('platform:cash', currency)
  end

  def expect_ledger_sound
    expect(Clearinghouse::Ledger::Invariants.check(app_db)).to be_empty
    expect(Clearinghouse::Ledger::Checker.run(app_db).drifts).to be_empty
  end

  describe 'a clean day' do
    it 'clears every capture and refund, and every flow is explained' do
      pi, = visa(10_000)
      yen, = visa(5_000, currency: 'jpy')
      re, = refunded(pi, 4_000)
      result = ingest(due_day)

      expect(result).to have_attributes(status: 'ingested', outcomes: { 'cleared' => 3 }, exceptions: {})
      expect(open_flows).to be_empty
      # 1.5% + 10 minor units, half-even: 160 cents on $100, 85 yen on 5000 yen.
      expect([cash, cash('jpy')]).to eq([10_000 - 160 - 4_000, 5_000 - 85])
      expect(balance_of('platform:processing_expense')).to eq(160)
      expect(app_db[:ledger_transactions].where(flow_id: [yen, re]).select_map(:description))
        .to include(match(/\Asettlement of #{yen} \(line ln_/), match(/\Asettlement of refund #{re} of #{pi}/))
      expect(exceptions).to be_empty
      expect_ledger_sound
    end

    it 'changes nothing when the same file is ingested again' do
      visa
      ingest(due_day)
      tables = %i[settlement_files settlement_lines ledger_transactions reconciliation_exceptions account_balances]
      before = tables.map { |t| app_db[t].all }
      expect(ingestor.ingest(due_day).status).to eq('already_ingested')
      expect(tables.map { |t| app_db[t].all }).to eq(before)
    end

    it 'stores the raw file and its hash' do
      visa
      ingest(due_day)
      file = app_db[:settlement_files].first
      expect(file).to include(settled_on: due_day, line_count: 1, requested_at: clock.now)
      expect(file[:sha256]).to eq(Digest::SHA256.hexdigest(file[:raw]))
      expect(app_db[:settlement_lines].select_map(%i[position type outcome])).to eq([[1, 'capture', 'cleared']])
    end
  end

  describe 'files it will not trust' do
    it 'refuses a date whose bytes changed since it was ingested' do
      visa
      ingest(due_day)
      raw = app_db[:settlement_files].get(:raw)
      expect do
        ingestor.ingest_csv(date: due_day, csv: raw.sub(',160,', ',161,'), requested_at: clock.now,
                            fetched_at: clock.now)
      end.to raise_error(Clearinghouse::Reconciliation::FileChangedError)
    end

    it 'refuses a malformed file without writing any of it' do
      header = Clearinghouse::Reconciliation::SettlementCsv::HEADER.join(',')
      good = "ln_1,capture,acq_1,op_1,100,11,usd,2026-03-04\n"
      [["nope\n", /header/],
       ["#{header}\n#{good}ln_2,capture,acq_2,op_2,1.5,0,usd,2026-03-04\n", /line 2 has a non-integer/],
       ["#{header}\nln_1,chargeback,acq_1,op_1,100,11,usd,2026-03-04\n", /unknown type/],
       ["#{header}\nln_1,capture,acq_1,op_1,100,11,xyz,2026-03-04\n", /unknown currency/],
       ["#{header}\nln_1,capture,acq_1,op_1,100,11,usd,2026-03-03\n", /settles on 2026-03-03/],
       ["#{header}\nln_1,capture,,op_1,100,11,usd,2026-03-04\n", /empty id/],
       ["#{header}\nln_1,capture,acq_1\n", /has 3 fields/]].each do |csv, error|
        expect { ingestor.ingest_csv(date: due_day, csv: csv, requested_at: clock.now, fetched_at: clock.now) }
          .to raise_error(Clearinghouse::Reconciliation::MalformedFileError, error)
      end
      expect(app_db[:settlement_files].count).to eq(0)
    end

    it 'flags a line in the wrong currency or for a payment with no capture, and books neither' do
      pi, ref = visa
      nocapture = insert_intent(app_db, merchant_id: merchant.id, status: 'succeeded', amount_received: 500,
                                        acquirer_reference: 'acq_nocapture').id
      csv = "#{Clearinghouse::Reconciliation::SettlementCsv::HEADER.join(',')}\n" \
            "ln_1,capture,#{ref},op_1,10000,160,eur,2026-03-04\n" \
            "ln_2,capture,acq_nocapture,op_2,500,18,usd,2026-03-04\n"
      on(due_day)
      result = ingestor.ingest_csv(date: due_day, csv: csv, requested_at: clock.now, fetched_at: clock.now)
      expect(result.outcomes).to eq('mismatch' => 1, 'unknown' => 1)
      wrong = exceptions('amount_mismatch').first
      expect(wrong).to include(flow_id: pi, unexplained_amount: 10_000)
      expect(wrong[:detail]).to eq("line is in eur, #{pi} is in usd")
      expect(exceptions('unknown_payment').first[:detail]).to eq("payment #{nocapture} has no capture in the ledger")
      expect(app_db[:settlement_lines].select_map(:ledger_transaction_id)).to eq([nil, nil])
    end

    it 'takes the reconciliation lock only inside a transaction' do
      expect { Clearinghouse::Reconciliation.lock!(app_db) }
        .to raise_error(Clearinghouse::Reconciliation::Error, /open transaction/)
    end

    it 'reports an unreachable acquirer' do
      down = Clearinghouse::Acquirer::Client.new(clock: clock, base_url: "http://127.0.0.1:#{SimServer.closed_port}")
      result = described_class.new(db: app_db, client: down, clock: clock).ingest(first_day)
      expect(result).to have_attributes(status: 'unavailable', lines: 0)
    end
  end

  describe 'the six discrepancies' do
    it 'books a duplicated line once and flags the copy' do
      pi, ref = visa
      result = ingest(due_day, inject: [{ type: 'duplicate', acquirer_reference: ref }])

      expect(result.outcomes).to eq('cleared' => 1, 'duplicate' => 1)
      rex = exceptions('duplicate').first
      expect(rex).to include(flow_id: pi, acquirer_reference: ref, line_type: 'capture', unexplained_amount: 0,
                             status: 'open')
      expect(app_db[:ledger_transactions].where(flow_id: pi).count).to eq(3) # capture, available, settlement
      expect(open_flows).to be_empty
    end

    it 'books the cash an amount mismatch really paid and leaves the difference in clearing' do
      pi, ref = visa
      ingest(due_day, inject: [{ type: 'amount_mismatch', acquirer_reference: ref, delta: 7 }])

      rex = exceptions('amount_mismatch').first
      expect(rex).to include(flow_id: pi, flow_type: 'payment', merchant_id: merchant.id, expected_amount: 10_000,
                             expected_fee: 160, clearing_account: 'platform:processor_receivable',
                             unexplained_amount: -7)
      expect(cash).to eq(10_007 - 160)
      expect(open_flows).to eq(pi => { %w[platform:processor_receivable usd] => -7 })
      expect_ledger_sound
    end

    it 'leaves an overcharged fee in clearing as money the acquirer owes us' do
      pi, ref = visa
      ingest(due_day, inject: [{ type: 'fee_mismatch', acquirer_reference: ref, delta: 3 }])
      expect(exceptions('fee_mismatch').first).to include(flow_id: pi, expected_fee: 160, unexplained_amount: 3)
      expect(cash).to eq(10_000 - 163)
      expect(balance_of('platform:processing_expense')).to eq(160)
      expect(open_flows).to eq(pi => { %w[platform:processor_receivable usd] => 3 })
    end

    it 'catches a refund line that took more than we refunded' do
      pi, ref = visa
      re, op = refunded(pi, 4_000)
      ingest(due_day, inject: [{ type: 'amount_mismatch', acquirer_reference: ref, line_type: 'refund', delta: 5 }])
      expect(exceptions('amount_mismatch').first)
        .to include(flow_id: re, operation_id: op, expected_amount: -4_000,
                    clearing_account: 'platform:refund_clearing', unexplained_amount: -5)
      expect(open_flows.keys).to eq([re])
    end

    it 'clears a late line when it arrives, once, and records that it was late' do
      pi, ref = visa
      expect(ingest(due_day, inject: [{ type: 'late', acquirer_reference: ref }]).lines).to eq(0)
      expect(open_flows.keys).to eq([pi])

      result = ingest(next_day)
      expect(result.outcomes).to eq('late' => 1)
      late = exceptions('late').first
      expect(late).to include(flow_id: pi, status: 'resolved', resolution_action: 'auto', unexplained_amount: 0)
      expect(late[:detail]).to include('due on 2026-03-04', 'missing from the 2026-03-04 file', '1 days after')
      expect(open_flows).to be_empty
      expect(app_db[:ledger_transactions].where(flow_id: pi).count).to eq(3)
      expect(cash).to eq(10_000 - 160)
    end

    it 'reports a late line that is also wrong for both' do
      pi, ref = visa
      ingest(due_day, inject: [{ type: 'late', acquirer_reference: ref }])
      result = ingest(next_day, inject: [{ type: 'amount_mismatch', acquirer_reference: ref, delta: 4 }])
      expect(result).to have_attributes(outcomes: { 'mismatch' => 1 },
                                        exceptions: { 'amount_mismatch' => 1, 'late' => 1 })
      expect(exceptions('late').first).to include(flow_id: pi, unexplained_amount: 0, status: 'resolved')
      expect(exceptions('amount_mismatch').first).to include(flow_id: pi, unexplained_amount: -4, status: 'open')
    end

    it 'does not call a line late when the acquirer carried it over because it happened after the file was built' do
      ingest(due_day)
      lagging_clock = Clearinghouse::Clock::Test.new(start: Time.utc(2026, 3, 2, 12))
      pi, = visa(at_clock: lagging_clock) # due on 03-04, whose file is already built
      result = ingest(next_day)

      carried = manifest(next_day)['carried_over']
      expect(carried).to contain_exactly(include('injected_late' => false, 'due_on' => '2026-03-04'))
      expect(result).to have_attributes(outcomes: { 'cleared' => 1 }, exceptions: {})
      expect(open_flows).not_to have_key(pi)
    end

    it 'flags a line for a payment we have never heard of and books nothing' do
      result = ingest(Date.new(2026, 3, 3), inject: [{ type: 'unknown_payment', amount: 2_500 }])
      expect(result.outcomes).to eq('unknown' => 1)
      rex = exceptions('unknown_payment').first
      expect(rex).to include(flow_id: nil, line_type: 'capture', unexplained_amount: 0)
      expect(rex[:detail]).to include('no payment has acquirer reference acq_')
      expect(app_db[:ledger_transactions].count).to eq(0)
    end

    it 'flags a refund we never issued' do
      pi, = visa
      re, = refunded(pi, 1_000)
      owner_db[:refunds].where(id: re).update(acquirer_operation_id: nil) # as if we had lost the mapping
      ingest(due_day)
      expect(exceptions('unknown_payment').first[:detail]).to include('no refund has acquirer operation op_')
    end
  end

  describe 'dispute lines' do
    def dispute_day(offset) = Date.new(2026, 3, 9) + offset

    it 'clears the debit when the dispute opens and the return when it is won' do
      pi, = captured_payment
      ingest(due_day)
      clock.advance_to(Time.utc(2026, 3, 9, 10))
      poller.poll
      ingest(dispute_day(2))
      expect(open_flows).to be_empty

      clock.advance(3600)
      resolve_at_acquirer('won')
      poller.poll
      dp = the_dispute.id
      expect(open_flows).to eq(dp => { %w[platform:dispute_clearing usd] => -10_000 })
      expect(ingest(dispute_day(3)).lines).to eq(0) # won on 03-11, so due on 03-13
      expect(ingest(dispute_day(4)).outcomes).to eq('cleared' => 1)
      expect(open_flows).to be_empty
      expect(app_db[:ledger_transactions].where(flow_id: dp).select_map(:description))
        .to include(match(/\Aacquirer debit for dispute #{dp} on #{pi}/), match(/\Aacquirer return for dispute #{dp}/))
      expect_ledger_sound
    end

    it 'holds a dispute line until the poller has told us about the dispute' do
      captured_payment
      ingest(due_day)
      result = ingest(dispute_day(2)) # the poller has not run since the dispute opened
      expect(result.outcomes).to eq('pending' => 1)
      expect(exceptions).to be_empty

      poller.poll
      expect(ingestor.match_pending).to eq(1)
      expect(app_db[:settlement_lines].where(type: 'dispute').get(:outcome)).to eq('cleared')
      expect(open_flows).to be_empty
    end

    it 'holds a reversal line until the win is recorded here' do
      captured_payment
      ingest(due_day)
      clock.advance_to(Time.utc(2026, 3, 9, 10))
      poller.poll
      ingest(dispute_day(2))
      resolve_at_acquirer('won') # on 03-11, so the reversal is due on 03-13
      expect(ingest(dispute_day(4)).outcomes).to eq('pending' => 1)
      expect(ingestor.match_pending).to eq(0)

      poller.poll
      expect(ingestor.match_pending).to eq(1)
      expect(open_flows).to be_empty
    end

    it 'matches pending lines from earlier files when the next file is ingested' do
      captured_payment
      ingest(due_day)
      ingest(dispute_day(2))
      poller.poll
      expect(ingest(dispute_day(3)).pending_matched).to eq(1)
    end

    it 'calls a dispute line for a payment we do not know an unknown payment' do
      acquirer_charge(payment_method: 'pm_card_disputeFraudulent')
      ingest(due_day)
      clock.advance_to(Time.utc(2026, 3, 11, 1))
      expect(ingestor.ingest(dispute_day(2)).outcomes).to eq('unknown' => 1)
      expect(exceptions('unknown_payment').map { |x| x[:line_type] }).to eq(%w[capture dispute])
    end
  end
end
