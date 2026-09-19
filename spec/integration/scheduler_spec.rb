# typed: false
# frozen_string_literal: true

require 'open3'

# The clock-driven worker against the real payments API, the real simulator and
# the real sweeps, one tick at a time on the test clock.
RSpec.describe Clearinghouse::Scheduler, :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'

  let(:scheduler) { described_class.new(deps, grace: 30) }
  let(:day) { Clearinghouse::Clock::SECONDS_PER_DAY }

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  it 'runs its steps in dependency order: the acquirer side before money moves, recovery last' do
    extra = described_class::Step.new(name: 'extra', run: ->(_, _) { {} })
    names = described_class.new(deps, extra_steps: [extra]).steps.map(&:name)
    expect(names).to eq(%w[expiry notifications settlement missing_lines extra availability payouts payout_resume
                           completer reaper])
  end

  it "applies the bank's payout.paid notification and ingests the day's settlement file" do
    intent = create_intent(amount: 10_000)
    confirm(intent['id'])
    clock.advance(2 * day)
    first = scheduler.tick!(clock)
    # The capture settles two days after it happened: in today's file, which reconciles it.
    expect(first.results['settlement']).to include('files' => { '2026-09-03' => 'ingested' }, 'lines' => 1)
    payout_id = first.results.dig('payouts', 'created').first
    expect(Clearinghouse::Payouts.find(app_db, payout_id).status).to eq('in_transit')

    clock.advance(day)
    report = scheduler.tick!(clock)
    expect(report.errors).to eq({})
    expect(report.results['notifications']).to include('processed' => 1, 'unavailable' => nil)
    expect(Clearinghouse::Payouts.find(app_db, payout_id).status).to eq('paid')
    expect(report.results['settlement']['files']).to eq('2026-09-04' => 'ingested')
    # Later ticks the same day don't ask for a file already ingested.
    expect(scheduler.tick!(clock).results['settlement']['files']).to eq({})
  end

  it "pays out, in the same tick, the money that tick's availability sweep released" do
    intent = create_intent(amount: 10_000)
    confirm(intent['id'])
    early = scheduler.tick!(clock)
    expect(early.results.slice('availability', 'payouts'))
      .to eq('availability' => { 'available' => 0, 'held' => 0 }, 'payouts' => { 'created' => [] })

    clock.advance(2 * day)
    report = scheduler.tick!(clock)
    expect([report.ok?, report.results['availability']]).to eq([true, { 'available' => 1, 'held' => 0 }])
    payout_id = report.results.dig('payouts', 'created').first
    expect(Clearinghouse::Payouts.find(app_db, payout_id)).to have_attributes(amount: money(9_680), automatic: true)
    expect(balance('available')).to eq(0)
    # A second tick the same day changes nothing.
    expect(scheduler.tick!(clock).results.dig('payouts', 'created')).to eq([])
  end

  it 'expires stale authorizations, finishes abandoned requests and reaps old keys' do
    held = create_intent(capture_method: 'manual')['id']
    confirm(held, {}, 'HTTP_IDEMPOTENCY_KEY' => 'auth')
    stuck = create_intent(payment_method: 'pm_card_timeout')['id']
    expect(confirm(stuck).status).to eq(503)

    clock.advance(31)
    first = scheduler.tick!(clock)
    expect(first.results['completer']).to include('completed' => [kind_of(Integer)], 'failed' => {})
    expect(intent_row(stuck)[:status]).to eq('succeeded')

    clock.advance(8 * day)
    later = scheduler.tick!(clock)
    expect(later.results['expiry']).to eq('expired' => [held])
    expect(intent_row(held)[:status]).to eq('canceled')
    expect(later.results['reaper']).to include('deleted' => 4, 'stuck' => 0)
  end

  it 'reports a failing step and still runs the others' do
    no_bank = Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock)
    capture!(merchant, 10_000, clock: clock)
    clock.advance(3 * day)
    report = described_class.new(no_bank).tick!(clock)
    expect(report.errors.keys).to eq(%w[notifications settlement payouts payout_resume])
    expect(report.errors['payouts']).to include('needs an acquirer client')
    expect(report.results['availability']).to eq('available' => 1, 'held' => 0)
    expect(report.results.keys).to include('expiry', 'completer', 'reaper')
  end

  it 'reads time from the clock it is given for every step, the completer and expiry included' do
    later = Clearinghouse::Clock::Test.new(start: clock.now + (10 * day))
    held = create_intent(capture_method: 'manual')['id']
    confirm(held)
    report = scheduler.tick!(later)
    expect([report.at, report.results['expiry']]).to eq([later.now, { 'expired' => [held] }])
    expect(scheduler.tick!.at).to eq(clock.now) # without an argument, the dependencies' clock
  end

  it 'runs as bin/scheduler, one JSON line per tick' do
    env = { 'CLEARINGHOUSE_ENV' => 'test', 'CLEARINGHOUSE_DB' => ENV.fetch('CLEARINGHOUSE_DB', 'clearinghouse_test'),
            'CLEARINGHOUSE_ACQUIRER_URL' => AcquirerSpec.server.url, 'RISKGATE_URL' => 'http://127.0.0.1:9' }
    out, status = Open3.capture2(env, File.expand_path('../../bin/scheduler', __dir__), '--once')
    expect(status.success?).to be(true)
    line = JSON.parse(out.lines.last)
    expect(line['steps'].keys).to eq(%w[expiry notifications settlement missing_lines availability payouts
                                        payout_resume completer reaper])
    expect(line['errors']).to eq({})
  end
end
