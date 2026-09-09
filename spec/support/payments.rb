# typed: false
# frozen_string_literal: true

DBHelper.clean_tables('events', 'payment_intents')

# Builders for payments specs.
module PaymentsSpecHelpers
  def insert_intent(db, merchant_id:, status: 'requires_confirmation', amount: 2000, currency: 'usd',
                    capture_method: 'automatic', payment_method: 'pm_card_visa', at: Time.utc(2026, 9, 1, 12), **extra)
    intent = Clearinghouse::Payments::PaymentIntent.new(
      id: Clearinghouse::Ids.generate('pi'), merchant_id: merchant_id, amount: amount, currency: currency,
      status: Clearinghouse::Payments::StateMachine::Status.deserialize(status), capture_method: capture_method,
      payment_method: payment_method, created_at: at, updated_at: at, **extra
    )
    Clearinghouse::Payments::PaymentIntents.insert!(db, intent)
  end
end

RSpec.configure { |c| c.include PaymentsSpecHelpers }
