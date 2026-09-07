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

# Requests against the payments endpoints, as a merchant (needs 'with the api app'
# and 'with a merchant').
module PaymentsApiHelpers
  FORM = { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }.freeze

  def api_post(path, params = {}, headers = {})
    post path, Rack::Utils.build_nested_query(params), auth.merge(FORM).merge(headers)
    last_response
  end

  def create_intent(amount: 2000, currency: 'usd', payment_method: 'pm_card_visa', capture_method: 'automatic', **rest)
    params = { amount: amount, currency: currency, capture_method: capture_method, **rest }
    params[:payment_method] = payment_method if payment_method
    response = api_post('/v1/payment_intents', params)
    raise "create failed: #{response.status} #{response.body}" unless response.status == 200

    JSON.parse(response.body)
  end

  def confirm(id, params = {}, headers = {})
    api_post("/v1/payment_intents/#{id}/confirm", params, headers)
  end

  def capture(id, params = {}, headers = {})
    api_post("/v1/payment_intents/#{id}/capture", params, headers)
  end

  def cancel(id, params = {}, headers = {})
    api_post("/v1/payment_intents/#{id}/cancel", params, headers)
  end

  def intent_row(id)
    ApiSpecHelpers.db[:payment_intents].where(id: id).first
  end

  def event_types(object_id)
    ApiSpecHelpers.db[:events].where(object_id: object_id).order(:seq).select_map(:type)
  end

  # Row counts of everything a refused request must not touch.
  def write_counts
    db = ApiSpecHelpers.db
    %i[ledger_transactions ledger_entries account_balances events].to_h { |t| [t, db[t].count] }
  end

  def balance(kind, currency = 'usd')
    Clearinghouse::Ledger.balance(ApiSpecHelpers.db, "merchant:#{merchant.id}:#{kind}", currency).amount
  end

  def platform_balance(code, currency = 'usd')
    Clearinghouse::Ledger.balance(ApiSpecHelpers.db, "platform:#{code}", currency).amount
  end
end

RSpec.configure { |c| c.include PaymentsApiHelpers }
