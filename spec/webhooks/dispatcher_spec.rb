# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::Dispatcher, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { Clearinghouse::Merchants.create(app_db, clock: clock, name: 'M', api_version: '2026-09-01').first }
  let(:dispatcher) { WebhookSpecHelpers.dispatcher(app_db, clock: clock) }

  def endpoint(events: ['*'], merchant_id: merchant.id)
    WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant_id, events: events)
  end

  def emit(type = 'payment_intent.succeeded', db: app_db, merchant_id: merchant.id)
    WebhookSpecHelpers.emit(db, clock: clock, merchant_id: merchant_id, type: type)
  end

  def pairs
    app_db[:webhook_deliveries].select_map(%i[event_id endpoint_id]).sort
  end

  def cursor
    app_db[:webhook_dispatch_cursors].where(name: 'default').get(:cursor_seq)
  end

  # The barrier waits for every older transaction in the cluster, and other test
  # databases share this cluster, so give their transactions a moment to finish.
  def run_until_cursor(seq, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until dispatcher.run_once.cursor >= seq
      raise "cursor stuck at #{cursor}, wanted #{seq}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def seq_of(event_id)
    app_db[:events].where(id: event_id).get(:seq)
  end

  it 'creates one delivery per subscribed endpoint' do
    all = endpoint
    payouts = endpoint(events: %w[payout.paid])
    intents = endpoint(events: %w[payment_intent.succeeded payout.paid])
    other_merchant = Clearinghouse::Merchants.create(app_db, clock: clock, name: 'O', api_version: '2026-09-01').first
    endpoint(merchant_id: other_merchant.id)

    succeeded = emit
    paid = emit('payout.paid')
    pass = dispatcher.run_once
    expect(pass).to have_attributes(scanned: 2, created: 5)
    expect(pairs).to contain_exactly([succeeded, all.id], [succeeded, intents.id], [paid, all.id], [paid, payouts.id],
                                     [paid, intents.id])
    row = WebhookSpecHelpers.delivery(app_db, paid)
    expect(row).to include(status: 'pending', attempts: 0, next_attempt_at: clock.now,
                           retry_deadline_at: clock.now + (3 * 86_400), event_created_at: clock.now)
  end

  it 'skips disabled and deleted endpoints, and endpoints created after the event' do
    disabled = endpoint
    Clearinghouse::Webhooks::Endpoints.update(app_db, clock: clock, endpoint: disabled, disabled: true,
                                                      url_check: WebhookSpecHelpers.url_check)
    Clearinghouse::Webhooks::Endpoints.delete(app_db, clock: clock, endpoint: endpoint)
    early = emit
    clock.advance(1)
    late = endpoint
    dispatcher.run_once
    expect(pairs).to be_empty

    later = emit
    dispatcher.run_once
    expect(pairs).to eq([[later, late.id]])
    expect(early).not_to eq(later)
  end

  it 'is idempotent: running again, or from scratch, never duplicates a delivery' do
    endpoint
    3.times { emit }
    dispatcher.run_until_idle
    count = app_db[:webhook_deliveries].count
    app_db[:webhook_dispatch_cursors].update(cursor_seq: 0, barrier_seq: nil, barrier_writers: nil)
    dispatcher.run_until_idle
    described_class.new(db: app_db, clock: clock, name: 'second').run_until_idle
    expect(app_db[:webhook_deliveries].count).to eq(count).and eq(3)
  end

  it 'moves the cursor only on the pass after the events were seen' do
    endpoint
    ids = Array.new(3) { emit }
    first = dispatcher.run_once
    expect(first.cursor).to eq(0)
    expect(app_db[:webhook_dispatch_cursors].get(:barrier_seq)).to eq(seq_of(ids.last))
    run_until_cursor(seq_of(ids.last))
    expect(dispatcher.run_once).to have_attributes(scanned: 0, cursor: seq_of(ids.last))
  end

  it 'works through a backlog in batches without skipping' do
    endpoint
    ids = Array.new(7) { emit }
    small = WebhookSpecHelpers.dispatcher(app_db, clock: clock, batch_size: 2)
    small.run_until_idle
    expect(pairs.map(&:first)).to match_array(ids)
    10.times { small.run_once }
    expect(cursor).to eq(seq_of(ids.last))
  end

  describe 'events that commit out of seq order' do
    # A second connection, so one transaction can hold a seq open while others commit.
    let(:other_db) { Clearinghouse::DB.connect(role: :app, max_connections: 1) }

    after { other_db.disconnect }

    it 'does not move the cursor past a seq whose transaction is still open, and delivers it after commit' do
      endpoint
      held_open = Thread::Queue.new
      release = Thread::Queue.new
      slow = Thread.new do
        other_db.transaction do
          id = emit(db: other_db)
          held_open << id
          release.pop
          id
        end
      end
      slow_id = held_open.pop
      begin
        fast_id = emit
        3.times { dispatcher.run_once }
        expect(pairs.map(&:first)).to eq([fast_id])
        expect(cursor).to be < seq_of(fast_id)
      ensure
        # Always let the open transaction finish, or the next example's TRUNCATE waits on it.
        release << true
        slow.join
      end
      expect(seq_of(slow_id)).to be < seq_of(fast_id)
      run_until_cursor(seq_of(fast_id))
      expect(pairs.map(&:first)).to contain_exactly(fast_id, slow_id)
    end

    it 'is not held back by a long transaction in another database' do
      # The first version waited for pg_snapshot_xmin, which is cluster-wide, and a
      # DROP DATABASE stuck in another test database stalled the cursor for minutes.
      elsewhere = Clearinghouse::DB.connect(role: :owner, database: 'postgres', max_connections: 1)
      holding = Thread::Queue.new
      release = Thread::Queue.new
      holder = Thread.new do
        elsewhere.transaction do
          elsewhere.get(Sequel.function(:pg_current_xact_id))
          holding << true
          release.pop
        end
      end
      holding.pop
      begin
        endpoint
        kept = emit
        run_until_cursor(seq_of(kept), timeout: 3)
        expect(cursor).to eq(seq_of(kept))
      ensure
        release << true
        holder.join
        elsewhere.disconnect
      end
    end

    it 'passes over the gap a rolled-back event leaves' do
      endpoint
      app_db.transaction(rollback: :always) { emit }
      kept = emit
      run_until_cursor(seq_of(kept))
      expect(pairs.map(&:first)).to eq([kept])
    end
  end

  it 'fails pending deliveries whose retry window has passed, unless they are leased' do
    endpoint
    stale = emit
    leased = emit
    dispatcher.run_once
    app_db[:webhook_deliveries].where(event_id: leased)
                               .update(lease_token: 'w:1', lease_expires_at: clock.now + (4 * 86_400))
    clock.advance((3 * 86_400) + 1)
    expect(dispatcher.run_once.expired).to eq(1)
    expect(WebhookSpecHelpers.delivery(app_db, stale)).to include(status: 'failed', last_error: 'retry_window_elapsed')
    expect(WebhookSpecHelpers.delivery(app_db, leased)[:status]).to eq('pending')
  end
end
