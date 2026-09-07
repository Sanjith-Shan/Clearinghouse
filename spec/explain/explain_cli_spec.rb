# typed: false
# frozen_string_literal: true

require 'open3'
require 'stringio'

# bin/explain against flows posted with Ledger::Flows. The text and JSON outputs are
# compared byte for byte with golden files in spec/fixtures/explain/, so a change to
# the output shows up as a readable diff in review.
#
# Regenerate with: UPDATE_GOLDEN=1 bundle exec rspec spec/explain
RSpec.describe Clearinghouse::ExplainCli, :db do
  let(:merchant) { 'acct_rocket' }
  let(:clock) { Clearinghouse::Clock::Test.new(start: LedgerHelpers::T0 + (10 * MoneyFlowHelpers::DAY)) }

  def post_event(flow_id, event, day:, description:, **args)
    Clearinghouse::Ledger.post!(app_db, flow_type: MoneyFlowHelpers::FLOW_TYPES.fetch(flow_id.split('_').first),
                                        flow_id: flow_id, description: description,
                                        effective_at: LedgerHelpers::T0 + (day * MoneyFlowHelpers::DAY),
                                        entries: flows.public_send(event, **args))
  end

  # A $100 payment that settled, a $40 refund of it that settled, and a dispute on it
  # that is still open. Refund and dispute descriptions name the payment, which is the
  # convention bin/explain finds related flows by.
  def payment_with_refund_and_dispute
    post_event('pi_1', :capture, day: 0, description: 'capture', merchant_id: merchant, gross: money(10_000),
                                 fee: money(320))
    post_event('pi_1', :settlement, day: 2, description: 'settlement', gross: money(10_000),
                                    acquirer_fee: money(160))
    post_event('pi_1', :funds_available, day: 2, description: 'funds available', merchant_id: merchant,
                                         net: money(9680))
    post_event('re_1', :refund, day: 3, description: 'refund re_1 of pi_1', merchant_id: merchant,
                                amount: money(4000))
    post_event('re_1', :refund_settled, day: 5, description: 'refund settled re_1 of pi_1', amount: money(4000))
    post_event('dp_1', :dispute_opened, day: 7, description: 'dispute dp_1 opened on pi_1', merchant_id: merchant,
                                        amount: money(6000), fee: money(1500))
  end

  # A payment whose settlement was booked for $99.00 instead of $100.00.
  def leaky_payment
    post_event('pi_2', :capture, day: 0, description: 'capture', merchant_id: merchant, gross: money(10_000),
                                 fee: money(320))
    post_event('pi_2', :settlement, day: 2, description: 'settlement', gross: money(9900), acquirer_fee: money(160))
  end

  def explain(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.run(argv, stdout: out, stderr: err, clock: clock)
    [status, out.string, err.string]
  end

  def expect_golden(name, actual)
    path = File.join(File.expand_path('../fixtures/explain', __dir__), name)
    File.write(path, actual) if ENV['UPDATE_GOLDEN']
    expect(File.exist?(path)).to be(true), "missing #{path}; run with UPDATE_GOLDEN=1"
    expect(actual).to eq(File.read(path))
  end

  describe 'text output' do
    it 'traces a payment with its refund and dispute and says EXPLAINED' do
      payment_with_refund_and_dispute
      status, out, err = explain('pi_1')
      expect([status, err]).to eq([0, ''])
      expect_golden('payment_with_related.txt', out)
      expect(out.lines.last.chomp).to eq('EXPLAINED  every clearing account this flow touched is back at zero ' \
                                         '(platform:processor_receivable)')
    end

    it 'says OPEN with the stuck amount and how long it has been open' do
      leaky_payment
      _, out, = explain('pi_2', '--as-of', '2026-01-06T04:30:00Z')
      expect_golden('open_payment.txt', out)
      expect(out.lines.last.chomp).to eq('OPEN  1.00 USD in platform:processor_receivable · open 5d 4h ' \
                                         '(since 2026-01-01 00:00 UTC, as of 2026-01-06 04:30 UTC)')
    end

    it 'shows the payment a refund belongs to' do
      payment_with_refund_and_dispute
      _, out, = explain('re_1')
      expect_golden('refund.txt', out)
    end

    it 'explains the flow a transaction id belongs to' do
      payment_with_refund_and_dispute
      transaction_id = app_db[:ledger_transactions].where(flow_id: 're_1').order(:id).get(:id)
      _, by_id, = explain(transaction_id.to_s)
      _, by_hash, = explain("##{transaction_id}")
      _, by_flow, = explain('re_1')
      expect(by_id).to eq(by_hash)
      expect(by_id).to include("Transaction ##{transaction_id} is part of this flow.")
      expect(by_id.sub(/^Transaction .*\n/, '')).to eq(by_flow)
    end

    it 'lists every open account on the last line of a flow stuck in two currencies' do
      post_event('po_1', :payout, day: 1, description: 'payout', merchant_id: merchant, amount: money(5000))
      post_event('po_1', :payout, day: 1, description: 'payout', merchant_id: merchant, amount: money(700, 'jpy'))
      _, out, = explain('po_1')
      expect(out.lines.last).to include('50.00 USD in platform:payout_clearing, 700 JPY in platform:payout_clearing')
      expect(out.lines.last).to include('open 9d')
    end

    it 'says so when a flow never touched clearing and nothing relates to it' do
      post_event('pi_3', :funds_available, day: 0, description: 'funds available', merchant_id: merchant,
                                           net: money(100))
      _, out, = explain('pi_3')
      expect(out).to include('Related flows: none found')
      expect(out.lines.last.chomp).to eq('EXPLAINED  this flow never touched a clearing account')
    end

    it 'does not relate pi_1 to a description naming pi_10' do
      payment_with_refund_and_dispute
      post_event('re_2', :refund, day: 4, description: 'refund re_2 of pi_10', merchant_id: merchant,
                                  amount: money(100))
      _, out, = explain('pi_1')
      expect(out).not_to include('re_2')
    end

    it 'skips a flow id named in a description that was never posted' do
      post_event('re_9', :refund, day: 1, description: 'refund re_9 of pi_404', merchant_id: merchant,
                                  amount: money(100))
      _, out, = explain('re_9')
      expect(out).to include('Related flows: none found')
    end

    it 'colors only when asked, or when stdout is a terminal' do
      leaky_payment
      _, plain, = explain('pi_2')
      _, colored, = explain('pi_2', '--color')
      expect(plain).not_to include("\e[")
      expect(colored).to include("\e[31mOPEN\e[0m", "\e[1mpi_2\e[0m")
      expect(colored.gsub(/\e\[[0-9;]*m/, '')).to eq(plain)
    end
  end

  describe 'JSON output' do
    it 'carries the same trace with amounts in minor units' do
      payment_with_refund_and_dispute
      _, out, = explain('pi_1', '--json')
      expect_golden('payment_with_related.json', out)
      body = JSON.parse(out)
      expect(body.values_at('flow_id', 'status', 'open_seconds', 'merchants')).to eq(['pi_1', 'explained', nil,
                                                                                      [merchant]])
      expect(body['related'].map { |r| r.values_at('flow_id', 'relation', 'explained') })
        .to eq([['re_1', 'mentions', true], ['dp_1', 'mentions', false]])
      expect(body['transactions'].first['entries'].first)
        .to eq('account' => 'platform:processor_receivable', 'kind' => 'clearing', 'side' => 'debit',
               'amount' => 10_000, 'currency' => 'usd', 'display' => '100.00 USD')
    end

    it 'reports what is stuck and for how long' do
      leaky_payment
      body = JSON.parse(explain('pi_2', '--json', '--as-of', '2026-01-06T04:30:00Z')[1])
      expect(body.values_at('status', 'open_seconds', 'opened_at')).to eq(['open', 448_200, '2026-01-01T00:00:00Z'])
      expect(body['stuck']).to eq([{ 'account' => 'platform:processor_receivable', 'currency' => 'usd',
                                     'amount' => 100, 'display' => '1.00 USD' }])
    end
  end

  describe 'errors' do
    it 'exits 1 for an id with no ledger transactions' do
      expect(explain('pi_nothing')).to eq([1, '', "No ledger transactions for pi_nothing.\n"])
      expect(explain('#999')).to eq([1, '', "No ledger transaction #999.\n"])
    end

    it 'exits 2 with usage for a bad command line' do
      [[], %w[pi_1 pi_2], %w[pi_1 --frobnicate], %w[pi_1 --as-of yesterday]].each do |argv|
        status, out, err = explain(*argv)
        expect([status, out]).to eq([2, ''])
        expect(err).to include('Usage: bin/explain')
      end
    end
  end

  describe '.duration' do
    it 'shows the two largest units' do
      expect([0, 40, 720, (3 * 3600) + (5 * 60) + 9, 86_400, 86_400 + 60, (5 * 86_400) + (4 * 3600) + 59]
               .map { |s| described_class.duration(s) })
        .to eq(['0s', '40s', '12m 0s', '3h 5m', '1d 0h', '1d 0h', '5d 4h'])
    end
  end

  it 'runs as bin/explain against the database named by --db' do
    leaky_payment
    script = File.expand_path('../../bin/explain', __dir__)
    out, err, status = Open3.capture3(script, 'pi_2', '--db', ENV.fetch('CLEARINGHOUSE_DB', 'clearinghouse_test'))
    expect(status.exitstatus).to eq(0), err
    expect(out).to start_with('pi_2 · payment · merchant acct_rocket · 2 transactions')
    expect(out).not_to include("\e[")
  end
end
