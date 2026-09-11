# typed: false
# frozen_string_literal: true

# From a card payment to the merchant's bank, through the real payments code, the
# real simulator and the events outbox: a capture schedules its availability, the
# sweep releases it, a payout sends it, and the bank's notification settles it.
RSpec.describe 'Payment to payout', :db do # rubocop:disable RSpec/DescribeClass
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'

  after { Clearinghouse::Ledger::Invariants.check!(app_db) }

  def release!
    Clearinghouse::Balances::Availability.release_due!(app_db, clock: clock)
  end

  it 'schedules the net at capture, releases it after the delay, and pays it out' do
    intent = create_intent(amount: 10_000)
    confirm(intent['id'])
    expect(JSON.parse(last_response.body)['status']).to eq('succeeded')

    scheduled = Clearinghouse::Balances::Availability.find(app_db, intent['id'])
    expect(scheduled).to have_attributes(merchant_id: merchant.id, net: money(9_680),
                                         available_on: Time.utc(2026, 9, 3), released_at: nil)
    get '/v1/balance', {}, auth
    expect(json_body).to include('pending' => [{ 'amount' => 9_680, 'currency' => 'usd' }],
                                 'available' => [{ 'amount' => 0, 'currency' => 'usd' }])

    clock.advance_to(Time.utc(2026, 9, 3))
    release!
    get '/v1/balance', {}, auth
    expect(json_body['available']).to eq([{ 'amount' => 9_680, 'currency' => 'usd' }])

    payout = JSON.parse(api_post('/v1/payouts').body)
    expect(payout).to include('amount' => 9_680, 'status' => 'in_transit')

    clock.advance(Clearinghouse::Clock::SECONDS_PER_DAY)
    acquirer.notifications(after: '0').data.each do |n|
      Clearinghouse::Payouts.handle_notification(app_db, n, clock: clock)
    end
    get "/v1/payouts/#{payout['id']}", {}, auth
    expect(json_body['status']).to eq('paid')
    expect(Clearinghouse::Ledger.explain(app_db, payout['id']).explained?).to be(true)
    expect(event_types(payout['id'])).to eq(%w[payout.created payout.paid])
  end

  it 'schedules only what a partial manual capture took' do
    intent = create_intent(amount: 10_000, capture_method: 'manual')
    confirm(intent['id'])
    capture(intent['id'], amount_to_capture: 6_000)
    expect(Clearinghouse::Balances::Availability.find(app_db, intent['id']).net).to eq(money(5_796))
  end

  it 'schedules nothing for a declined payment' do
    intent = create_intent(amount: 10_000, payment_method: 'pm_card_chargeDeclined')
    confirm(intent['id'])
    expect(Clearinghouse::Balances::Availability.find(app_db, intent['id'])).to be_nil
  end
end
