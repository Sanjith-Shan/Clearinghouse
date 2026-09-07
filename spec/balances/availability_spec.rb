# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Balances::Availability, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 15, 30)) }
  let(:merchant) { new_merchant(clock: clock) }
  let(:availability) { described_class }

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  def funds_available_count(flow_id)
    app_db[:ledger_transactions].where(flow_id: flow_id, description: 'funds available').count
  end

  describe '.available_on_for' do
    it "is the start of the UTC day, the merchant's delay days after capture" do
      expect(availability.available_on_for(app_db, merchant_id: merchant.id, captured_at: clock.now))
        .to eq(Time.utc(2026, 9, 3))
    end

    it 'follows a merchant with no delay to the same day' do
      same_day = new_merchant(clock: clock, payout_delay_days: 0)
      expect(availability.available_on_for(app_db, merchant_id: same_day.id, captured_at: Time.utc(2026, 9, 1, 23, 59)))
        .to eq(Time.utc(2026, 9, 1))
    end

    it 'refuses an unknown merchant' do
      expect { availability.available_on_for(app_db, merchant_id: 'acct_missing', captured_at: clock.now) }
        .to raise_error(described_class::MerchantNotFoundError)
    end
  end

  describe '.schedule!' do
    let(:flow_id) { Clearinghouse::Ids.generate('pi') }
    let(:on) { Time.utc(2026, 9, 3) }

    def schedule(net, available_on: on, merchant_id: merchant.id)
      availability.schedule!(app_db, flow_id: flow_id, merchant_id: merchant_id, net: money(net),
                                     available_on: available_on, clock: clock)
    end

    it 'stores the release, unreleased' do
      scheduled = schedule(9_680)
      expect(scheduled).to have_attributes(flow_id: flow_id, merchant_id: merchant.id, net: money(9_680),
                                           available_on: on, released_at: nil, released_to: nil)
    end

    it 'returns the same row when called again with the same terms, so a retried capture phase is safe' do
      first = schedule(9_680)
      expect(schedule(9_680).id).to eq(first.id)
      expect(app_db[:scheduled_availabilities].count).to eq(1)
    end

    it 'refuses the same flow with a different amount or date' do
      schedule(9_680)
      expect { schedule(9_681) }.to raise_error(described_class::ConflictError, /already scheduled/)
      expect { schedule(9_680, available_on: on + 1) }.to raise_error(described_class::ConflictError)
    end

    it 'schedules nothing for a zero net and refuses a negative one' do
      expect(schedule(0)).to be_nil
      expect { schedule(-1) }.to raise_error(ArgumentError)
      expect(app_db[:scheduled_availabilities].count).to eq(0)
    end
  end

  describe '.release_due!' do
    it 'moves the net from pending to available once the clock reaches available_on, and not before' do
      flow_id, net = capture!(merchant, 10_000, clock: clock)
      expect(net).to eq(money(9_680))

      clock.advance_to(Time.utc(2026, 9, 2, 23, 59, 59))
      expect(availability.release_due!(app_db, clock: clock).released).to be_empty
      expect(merchant_balance(merchant, 'pending')).to eq(9_680)

      clock.advance_to(Time.utc(2026, 9, 3))
      report = availability.release_due!(app_db, clock: clock)
      expect(report.released.map(&:flow_id)).to eq([flow_id])
      expect(report.count('available')).to eq(1)
      expect(merchant_balance(merchant, 'pending')).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
      expect(availability.find(app_db, flow_id)).to have_attributes(released_at: clock.now, released_to: 'available')
    end

    it 'dates the posting at available_on even when the sweep runs late' do
      flow_id, = capture!(merchant, 10_000, clock: clock)
      clock.advance(10 * BalanceHelpers::DAY)
      availability.release_due!(app_db, clock: clock)
      txn = app_db[:ledger_transactions].where(flow_id: flow_id, description: 'funds available').first
      expect(txn[:effective_at]).to eq(Time.utc(2026, 9, 3))
      expect(app_db[:scheduled_availabilities].where(flow_id: flow_id).get(:release_transaction_id)).to eq(txn[:id])
    end

    it 'releases a row once, however many times the sweep runs' do
      flow_id, = capture!(merchant, 10_000, clock: clock)
      clock.advance(3 * BalanceHelpers::DAY)
      3.times { availability.release_due!(app_db, clock: clock) }
      expect(funds_available_count(flow_id)).to eq(1)
      expect(merchant_balance(merchant, 'available')).to eq(9_680)
    end

    it 'pages through more due rows than one batch holds' do
      flows = Array.new(7) { capture!(merchant, 1_000, clock: clock).first }
      clock.advance(3 * BalanceHelpers::DAY)
      report = availability.release_due!(app_db, clock: clock, batch_size: 3)
      expect(report.released.map(&:flow_id)).to match_array(flows)
      expect(merchant_balance(merchant, 'available')).to eq(7 * 941)
    end

    it 'rolls a batch back whole when it crashes halfway, and the next sweep releases every row exactly once' do
      flows = Array.new(5) { capture!(merchant, 1_000, clock: clock).first }
      clock.advance(3 * BalanceHelpers::DAY)
      calls = 0
      allow(Clearinghouse::Ledger).to receive(:post!).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        raise 'simulated crash on the third release' if calls == 3

        original.call(*args, **kwargs)
      end

      expect { availability.release_due!(app_db, clock: clock) }.to raise_error(/simulated crash/)
      expect(app_db[:scheduled_availabilities].exclude(released_at: nil).count).to eq(0)
      expect(merchant_balance(merchant, 'available')).to eq(0)

      availability.release_due!(app_db, clock: clock)
      expect(flows.map { |f| funds_available_count(f) }).to all(eq(1))
      expect(merchant_balance(merchant, 'available')).to eq(5 * 941)
      expect(merchant_balance(merchant, 'pending')).to eq(0)
    end

    it 'never double-releases when sweeps run concurrently (real threads, real Postgres)' do
      flows = Array.new(40) { capture!(merchant, 1_000, clock: clock).first }
      clock.advance(3 * BalanceHelpers::DAY)

      reports = run_concurrently(4) { availability.release_due!(app_db, clock: clock, batch_size: 3) }

      released = reports.flat_map { |r| r.released.map(&:flow_id) }
      expect(released).to match_array(flows) # every row once, across all sweeps together
      expect(flows.map { |f| funds_available_count(f) }).to all(eq(1))
      expect(merchant_balance(merchant, 'available')).to eq(40 * 941)
      expect(merchant_balance(merchant, 'pending')).to eq(0)
    end

    it 'skips rows another sweep has claimed instead of waiting for them' do
      flows = Array.new(4) { capture!(merchant, 1_000, clock: clock).first }
      clock.advance(3 * BalanceHelpers::DAY)
      claimed = Queue.new
      finish = Queue.new
      holder = Thread.new do
        app_db.transaction do
          ids = app_db[:scheduled_availabilities].order(:id).limit(2).for_update.select_map(:flow_id)
          claimed << ids
          finish.pop
        end
      end
      locked = claimed.pop

      report = availability.release_due!(app_db, clock: clock)
      expect(report.released.map(&:flow_id)).to match_array(flows - locked)

      finish << :done
      holder.join
      expect(availability.release_due!(app_db, clock: clock).released.map(&:flow_id)).to match_array(locked)
    end
  end
end
