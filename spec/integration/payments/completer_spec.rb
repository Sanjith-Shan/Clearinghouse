# typed: false
# frozen_string_literal: true

# The completer and reaper on the real payments flows and the real acquirer.
RSpec.describe Clearinghouse::Idempotency::Completer, :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'

  let(:completer) { Clearinghouse::Api::Completion.completer(deps, grace: 30) }
  let(:keys) { ApiSpecHelpers.db[:idempotency_keys] }

  def ledger_captures(id)
    ApiSpecHelpers.db[:ledger_transactions].where(flow_id: id, description: 'capture').count
  end

  it 'finishes a keyless confirm whose acquirer answer was lost, charging once' do
    id = create_intent(payment_method: 'pm_card_timeout')['id']
    expect(confirm(id).status).to eq(503)
    key = keys.where(client_supplied: false, flow: 'payment_intent.confirm').first
    expect(key).to include(recovery_point: 'authorization_requested', locked_at: nil)

    expect(completer.run_once.completed).to be_empty # inside the grace period, a client may still retry
    clock.advance(30)
    report = completer.run_once
    expect([report.completed, report.failed]).to eq([[key[:id]], []])
    expect(intent_row(id)).to include(status: 'succeeded', locked_by: nil)
    expect([acquirer_charges(id).length, acquirer_captures(id), ledger_captures(id), acquirer.calls.map(&:first)])
      .to eq([1, 1, 1, %i[authorize lookup]])
    events = ApiSpecHelpers.db[:events].where(object_id: id).order(:seq).select_map(%i[type request_id])
    expect(events.last).to eq(['payment_intent.succeeded', key[:request_id]])
    expect(completer.run_once.completed).to be_empty
  end

  it "stores the response the client's retry then replays, at the version it asked for" do
    id = create_intent['id']
    acquirer.fail_next(:authorize, :drop)
    headers = { 'HTTP_IDEMPOTENCY_KEY' => 'k1', 'HTTP_CLEARINGHOUSE_VERSION' => '2026-01-01' }
    expect(confirm(id, {}, headers).status).to eq(503)
    clock.advance(30)
    expect(completer.run_once.completed.length).to eq(1)
    replay = confirm(id, {}, headers)
    expect(replay.headers['idempotent-replayed']).to eq('true')
    expect(JSON.parse(replay.body)).to include('status' => 'succeeded', 'amount_captured' => 2000)
  end

  it 'resumes a request whose process died holding the lease, once the lease expires' do
    id = create_intent(capture_method: 'manual')['id']
    confirm(id)
    acquirer.fail_next(:void, :drop)
    cancel(id, {}, 'HTTP_IDEMPOTENCY_KEY' => 'c1')
    # What a crash leaves: still leased, by a process that will never come back.
    keys.where(key: 'c1').update(locked_at: clock.now, lock_token: 'dead')
    clock.advance(59)
    expect(completer.run_once.completed).to be_empty
    clock.advance(2)
    expect(completer.run_once.completed.length).to eq(1)
    expect(intent_row(id)).to include(status: 'canceled', locked_by: nil)
    expect(acquirer.calls.map(&:first)).to eq(%i[authorize void lookup])
  end

  it 'leaves a key where it is when the acquirer still does not answer, and tries again later' do
    id = create_intent(payment_method: 'pm_card_timeout')['id']
    confirm(id)
    clock.advance(30)
    acquirer.fail_next(:lookup, :unavailable)
    report = completer.run_once
    expect(report.failed.map(&:last)).to eq(['Clearinghouse::Api::Errors::AcquirerUnavailableError: ' \
                                             'The card network is unavailable. The payment has not failed; ' \
                                             'retry the request with the same Idempotency-Key.'])
    expect(intent_row(id)[:status]).to eq('processing')
    clock.advance(30)
    expect(completer.run_once.completed.length).to eq(1)
    expect(intent_row(id)[:status]).to eq('succeeded')
  end

  it 'reports a key another runner took first as busy' do
    id = create_intent(payment_method: 'pm_card_timeout')['id']
    confirm(id)
    clock.advance(30)
    record = completer.candidates.first
    keys.where(id: record.id).update(locked_at: clock.now, lock_token: 'client-retry')
    busy = described_class.new(db: ApiSpecHelpers.db, clock: clock, lock_timeout: 60, grace: 0,
                               resumer: ->(r) { Clearinghouse::Api::Completion.resume(deps, r) })
    allow(busy).to receive(:candidates).and_return([record])
    expect(busy.run_once.busy).to eq([record.id])
  end

  describe Clearinghouse::Idempotency::Reaper do
    it 'deletes finished keys after 24 hours and never an unfinished one' do
      id = create_intent['id']
      confirm(id, {}, 'HTTP_IDEMPOTENCY_KEY' => 'done')
      stuck = create_intent(payment_method: 'pm_card_timeout')['id']
      confirm(stuck, {}, 'HTTP_IDEMPOTENCY_KEY' => 'stuck')
      clock.advance((24 * 3600) - 1)
      expect(described_class.run(ApiSpecHelpers.db, clock: clock).deleted).to eq(0)
      clock.advance(1)
      report = described_class.run(ApiSpecHelpers.db, clock: clock)
      # Two creates and a confirm finished; the timed-out confirm did not.
      expect([report.deleted, report.stuck]).to eq([3, 1])
      expect(keys.select_map(:key)).to eq(['stuck'])
      # The key is free again: it runs, and meets an intent that has already succeeded.
      response = confirm(id, { payment_method: 'pm_card_mastercard' }, 'HTTP_IDEMPOTENCY_KEY' => 'done')
      expect(JSON.parse(response.body).dig('error', 'code')).to eq('payment_intent_unexpected_state')
    end
  end
end
