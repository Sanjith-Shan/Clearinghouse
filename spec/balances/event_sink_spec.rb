# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Balances::OutboxEventSink, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:merchant) { new_merchant(clock: clock) }

  it 'knows every type this area emits as an outbox event type' do
    expect(Clearinghouse::Events::TYPES).to include(*Clearinghouse::Balances::EVENT_TYPES)
  end

  it 'writes the event to the outbox, where it rolls back with the change it reports' do
    app_db.transaction do
      described_class.new.emit!(app_db, merchant_id: merchant.id, type: 'payout.created',
                                        object: { 'id' => 'po_1', 'object' => 'payout' }, clock: clock)
    end
    app_db.transaction(rollback: :always) do
      described_class.new.emit!(app_db, merchant_id: merchant.id, type: 'payout.paid',
                                        object: { 'id' => 'po_1', 'object' => 'payout' }, clock: clock)
    end
    expect(app_db[:events].where(object_id: 'po_1').select_map(:type)).to eq(['payout.created'])
  end
end
