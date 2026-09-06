# typed: false
# frozen_string_literal: true

# The database's own backstops for payment intents and the outbox, tested in raw
# SQL as the app role, with no Payments code involved.
RSpec.describe 'payments schema', :db do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:t0) { Time.utc(2026, 9, 1) }

  def raw_intent(**overrides)
    row = { id: Clearinghouse::Ids.generate('pi'), merchant_id: merchant.id, amount: 1000, currency: 'usd',
            status: 'requires_payment_method', capture_method: 'automatic', created_at: t0, updated_at: t0 }
    app_db[:payment_intents].insert(row.merge(overrides))
    row[:id]
  end

  def expect_violation(constraint, &)
    expect(&).to raise_error(Sequel::CheckConstraintViolation, /#{constraint}/)
  end

  it 'accepts a plain new intent' do
    id = raw_intent
    expect(app_db[:payment_intents].where(id: id).get(:status)).to eq('requires_payment_method')
  end

  it 'refuses refunds beyond what was received, whatever the application thinks' do
    id = raw_intent(status: 'succeeded', amount_received: 600)
    app_db[:payment_intents].where(id: id).update(amount_refunded: 600)
    expect_violation('payment_intents_refunds_within_received') do
      app_db[:payment_intents].where(id: id).update(amount_refunded: 601)
    end
  end

  it 'refuses a capturable amount outside requires_capture, and requires_capture without an authorization' do
    expect_violation('payment_intents_capturable_only_when_waiting') { raw_intent(amount_capturable: 10) }
    expect_violation('payment_intents_waiting_has_authorization') { raw_intent(status: 'requires_capture') }
  end

  it 'refuses a succeeded intent with nothing received, and money received in any other status' do
    expect_violation('payment_intents_succeeded_received') { raw_intent(status: 'succeeded') }
    expect_violation('payment_intents_received_only_when_succeeded') do
      raw_intent(status: 'canceled', amount_received: 5)
    end
  end

  it 'refuses an unknown status and a malformed id' do
    expect_violation('status') { raw_intent(status: 'charged') }
    expect_violation('id') { raw_intent(id: 'pi_short') }
  end

  it 'lets the app role update intents but never delete them' do
    id = raw_intent
    expect { app_db[:payment_intents].where(id: id).delete }.to raise_error(Sequel::DatabaseError, /permission denied/)
  end

  it 'lets the app role insert and read events but not edit or delete them' do
    app_db[:events].insert(id: Clearinghouse::Ids.generate('evt'), merchant_id: merchant.id, type: 'charge.refunded',
                           object_id: 'ch_1', data: Sequel.cast('{}', :json), created_at: t0)
    expect { app_db[:events].update(type: 'charge.dispute.created') }
      .to raise_error(Sequel::DatabaseError, /permission denied/)
    expect { app_db[:events].delete }.to raise_error(Sequel::DatabaseError, /permission denied/)
  end
end
