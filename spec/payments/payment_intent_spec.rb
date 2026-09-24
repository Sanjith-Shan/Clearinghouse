# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Payments::PaymentIntent, :db do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:intents) { Clearinghouse::Payments::PaymentIntents }
  let(:status) { Clearinghouse::Payments::StateMachine::Status }

  # The fixture is the contract with the versioning work: the serializer must
  # produce exactly it, so the golden files for every version hold.
  def from_fixture(json, **overrides)
    described_class.new(
      id: json['id'], merchant_id: merchant.id, amount: json['amount'], currency: json['currency'],
      amount_capturable: json['amount_capturable'], amount_received: json['amount_received'],
      status: status.deserialize(json['status']), capture_method: json['capture_method'],
      payment_method: json['payment_method'], customer_email: json['customer_email'], metadata: json['metadata'],
      latest_charge: json['latest_charge'], last_payment_error: json['last_payment_error'],
      cancellation_reason: json['cancellation_reason'], risk: json['risk'],
      created_at: Time.at(json['created']).utc, updated_at: Time.at(json['created']).utc, **overrides
    )
  end

  %w[payment_intent payment_intent_declined].each do |name|
    it "serializes to exactly the #{name} fixture, key order included" do
      json = fixture(name)
      expect(JSON.pretty_generate(from_fixture(json).to_api)).to eq(JSON.pretty_generate(json))
    end

    it "round-trips the #{name} fixture through the database unchanged" do
      extra = name == 'payment_intent' ? { acquirer_reference: 'acq_1', authorized_at: clock.now } : {}
      intent = from_fixture(fixture(name), **extra)
      intents.insert!(app_db, intent)
      expect(intents.find(app_db, merchant_id: merchant.id, id: intent.id)).to eq(intent)
    end
  end

  it 'is not found by another merchant' do
    intent = insert_intent(app_db, merchant_id: merchant.id)
    other, = Clearinghouse::Merchants.create(app_db, clock: clock, name: 'Other', api_version: '2026-09-01')
    expect(intents.find(app_db, merchant_id: other.id, id: intent.id)).to be_nil
    expect { intents.find!(app_db, merchant_id: other.id, id: intent.id) }
      .to raise_error(Clearinghouse::Api::Errors::NotFoundError, /No such payment_intent/)
  end

  describe 'save!' do
    it 'bumps lock_version and refuses a write based on a stale read' do
      intent = insert_intent(app_db, merchant_id: merchant.id)
      saved = intents.save!(app_db, intent, intent.copy(customer_email: 'a@example.com'), now: clock.now)
      expect(saved.lock_version).to eq(1)
      expect { intents.save!(app_db, intent, intent.copy(customer_email: 'b@example.com'), now: clock.now) }
        .to raise_error(intents::StaleError)
      expect(intents.find(app_db, merchant_id: merchant.id, id: intent.id).customer_email).to eq('a@example.com')
    end

    it 'refuses to write one intent over another' do
      a = insert_intent(app_db, merchant_id: merchant.id)
      b = insert_intent(app_db, merchant_id: merchant.id)
      expect { intents.save!(app_db, a, b, now: clock.now) }
        .to raise_error(ArgumentError, 'cannot change an intent into another one')
      expect(intents.find(app_db, merchant_id: merchant.id, id: a.id).lock_version).to eq(0)
    end

    it 'refuses to lock outside a transaction' do
      intent = insert_intent(app_db, merchant_id: merchant.id)
      expect { intents.lock!(app_db, merchant_id: merchant.id, id: intent.id) }
        .to raise_error(Clearinghouse::Error, /open transaction/)
    end
  end

  describe 'copy and equality' do
    it 'refuses to copy with a field the struct does not have, so a typo cannot be silently dropped' do
      intent = insert_intent(app_db, merchant_id: merchant.id)
      expect { intent.copy(amount_recieved: 5, status: status::Succeeded) }
        .to raise_error(ArgumentError, 'unknown fields amount_recieved')
    end

    it 'compares by value, and never equals something that is not an intent' do
      intent = insert_intent(app_db, merchant_id: merchant.id)
      expect(intent.copy).to eq(intent)
      expect(intent.copy(amount: 1)).not_to eq(intent)
      expect(intent == intent.fields).to be(false)
    end
  end

  describe 'the charge' do
    it 'is nil before an authorization, and reports captures and refunds after one' do
      intent = insert_intent(app_db, merchant_id: merchant.id)
      expect(intent.charge_to_api).to be_nil
      charged = intent.copy(latest_charge: Clearinghouse::Ids.generate('ch'), status: status::Succeeded,
                            amount_received: 2000, amount_refunded: 2000, authorized_at: clock.now)
      expect(charged.charge_to_api).to include('object' => 'charge', 'amount_captured' => 2000, 'captured' => true,
                                               'refunded' => true, 'payment_intent' => intent.id)
    end
  end

  it 'derives the acquirer key from the id and the attempt, and has none before the first attempt' do
    intent = insert_intent(app_db, merchant_id: merchant.id)
    expect { intent.authorization_key }.to raise_error(Clearinghouse::Error, /not been confirmed/)
    expect(intent.copy(attempt: 2).authorization_key).to eq("#{intent.id}:authorize:2")
  end

  describe 'list' do
    it 'pages newest first with starting_after' do
      ids = (0...5).map { |i| insert_intent(app_db, merchant_id: merchant.id, at: clock.now + i).id }.reverse
      page, more = intents.list(app_db, merchant_id: merchant.id, limit: 2)
      expect([page.map(&:id), more]).to eq([ids[0, 2], true])
      page, more = intents.list(app_db, merchant_id: merchant.id, limit: 2, starting_after: ids[1])
      expect([page.map(&:id), more]).to eq([ids[2, 2], true])
      page, more = intents.list(app_db, merchant_id: merchant.id, limit: 2, starting_after: ids[3])
      expect([page.map(&:id), more]).to eq([ids[4, 1], false])
    end
  end
end
