# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::Endpoints, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { Clearinghouse::Merchants.create(app_db, clock: clock, name: 'M', api_version: '2026-09-01').first }

  def create(**options)
    WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id, **options)
  end

  it 'stores the endpoint and reads it back' do
    endpoint = create(events: %w[payout.paid payout.paid charge.refunded])
    found = described_class.find(app_db, merchant.id, endpoint.id)
    expect(found.serialize).to eq(endpoint.serialize)
    expect(found.enabled_events).to eq(%w[payout.paid charge.refunded])
    expect(found.subscribed?('payout.paid')).to be(true)
    expect(found.subscribed?('payout.failed')).to be(false)
  end

  it 'subscribes a wildcard endpoint to everything' do
    expect(create(events: ['*']).subscribed?('webhook_endpoint.disabled')).to be(true)
  end

  it 'rolls secrets, keeping at most two live and dropping an expired one' do
    endpoint = create
    original = endpoint.secrets.current
    rolled = described_class.roll_secret(app_db, clock: clock, endpoint: endpoint, overlap: 600)
    expect(rolled.secrets.previous).to eq(original)
    clock.advance(601)
    again = described_class.roll_secret(app_db, clock: clock, endpoint: endpoint, overlap: 600)
    expect(again.secrets.previous).to eq(rolled.secrets.current)
    expect(again.secrets.active_secrets(now: clock.now)).not_to include(original)
  end

  it 'loses no secret when two rolls race' do
    endpoint = create
    threads = Array.new(4) do
      Thread.new { described_class.roll_secret(app_db, clock: clock, endpoint: endpoint, overlap: 600) }
    end
    results = threads.map(&:value)
    final = described_class.find(app_db, merchant.id, endpoint.id)
    # Each roll saw the one before it, so the final previous secret is the
    # second-to-last roll's current secret rather than one that was never live.
    currents = results.map { |r| r.secrets.current }
    expect(currents.uniq.length).to eq(4)
    expect(currents).to include(final.secrets.previous)
  end

  it 'stores the signing secret itself, because signing needs it (a real system would encrypt it)' do
    endpoint = create
    stored = app_db[:webhook_endpoints].where(id: endpoint.id).get(:secret)
    expect(stored).to eq(endpoint.secrets.current)
  end

  describe 'database rules' do
    it 'refuses DELETE for the app role, since deletes are soft' do
      endpoint = create
      expect { app_db[:webhook_endpoints].where(id: endpoint.id).delete }
        .to raise_error(Sequel::DatabaseError, /permission denied/)
    end

    it 'refuses a disabled endpoint without a reason' do
      endpoint = create
      expect { app_db[:webhook_endpoints].where(id: endpoint.id).update(status: 'disabled') }
        .to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'refuses UPDATE and DELETE on events' do
      id = Clearinghouse::Events.emit!(app_db, merchant_id: merchant.id, type: 'payout.paid',
                                               object: { 'id' => 'po_1', 'object' => 'payout' }, clock: clock)
      expect { app_db[:events].where(id: id).update(type: 'payout.failed') }
        .to raise_error(Sequel::DatabaseError, /permission denied/)
      expect { app_db[:events].where(id: id).delete }.to raise_error(Sequel::DatabaseError, /permission denied/)
    end
  end
end
