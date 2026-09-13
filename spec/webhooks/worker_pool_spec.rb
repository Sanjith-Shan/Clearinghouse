# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::WorkerPool, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:server) { LocalHttpServer.new { |socket, _| LocalHttpServer.respond(socket, 200) } }

  after { server.stop }

  it 'delivers everything with several threads and stops cleanly' do
    merchant = Clearinghouse::Merchants.create(app_db, clock: clock, name: 'M', api_version: '2026-09-01').first
    WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id,
                                               url: "http://127.0.0.1:#{server.port}/")
    ids = Array.new(30) { WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id) }
    WebhookSpecHelpers.dispatcher(app_db, clock: clock).run_until_idle

    pool = described_class.new(threads: 4, idle_sleep: 0.01) do |i|
      WebhookSpecHelpers.worker(app_db, clock: clock, seed: i, name: "t#{i}")
    end.start
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.02 until app_db[:webhook_deliveries].where(status: 'succeeded').count == 30 ||
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    pool.stop

    expect(app_db[:webhook_deliveries].where(status: 'succeeded').count).to eq(30)
    expect(server.requests.map { |r| JSON.parse(r.body)['id'] }).to match_array(ids)
  end

  it 'keeps a thread alive when the database errors, and logs it' do
    log = StringIO.new
    worker = WebhookSpecHelpers.worker(app_db, clock: clock, name: 'flaky')
    calls = 0
    allow(worker).to receive(:work_once) do
      calls += 1
      raise Sequel::DatabaseDisconnectError, 'gone' if calls == 1

      nil
    end
    pool = described_class.new(threads: 1, idle_sleep: 0.001, log: log) { worker }.start
    sleep 0.001 until calls > 2
    pool.stop
    expect(log.string).to include('"exception":"Sequel::DatabaseDisconnectError"', '"worker":"flaky"')
  end
end
