# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Events, :db do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:intent_json) { fixture('payment_intent') }

  def emit(db = app_db, type: 'payment_intent.succeeded')
    described_class.emit!(db, merchant_id: merchant.id, type: type, object: intent_json, clock: clock)
  end

  it 'stores the object at the latest version with simulated time, and renders the agreed envelope' do
    id = emit
    row = app_db[:events].where(id: id).first
    expect(row).to include(merchant_id: merchant.id, type: 'payment_intent.succeeded',
                           object_id: intent_json['id'], created_at: clock.now)
    expected = fixture('event_payment_intent_succeeded').merge('id' => id, 'created' => clock.now.to_i)
    expect(described_class.envelope(row)).to eq(expected)
  end

  it 'numbers events in insert order' do
    ids = [emit, emit(type: 'payment_intent.canceled'), emit]
    expect(app_db[:events].order(:seq).select_map(:id)).to eq(ids)
  end

  it 'lists every event for an object, oldest first' do
    first = emit(type: 'payment_intent.amount_capturable_updated')
    second = emit
    expect(described_class.for_object(app_db, intent_json['id']).map { |e| e['id'] }).to eq([first, second])
  end

  it 'records the request that caused it' do
    request = described_class::Request.new(id: 'req_1', idempotency_key: 'k1')
    id = described_class.emit!(app_db, merchant_id: merchant.id, type: 'charge.refunded', object: intent_json,
                                       clock: clock, request: request)
    expect(app_db[:events].where(id: id).first).to include(request_id: 'req_1', idempotency_key: 'k1')
  end

  it 'refuses a type nobody could subscribe to' do
    expect { emit(type: 'payment_intent.succeded') }.to raise_error(described_class::UnknownTypeError)
    expect(app_db[:events].count).to eq(0)
  end

  it 'rolls back with the transaction it was written in' do
    app_db.transaction do
      emit
      raise Sequel::Rollback
    end
    expect(app_db[:events].count).to eq(0)
  end
end
