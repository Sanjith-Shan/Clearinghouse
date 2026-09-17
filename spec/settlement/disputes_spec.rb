# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Disputes::Service, :db do
  include SettlementHelpers
  include DisputeHelpers

  let(:day) { SettlementHelpers::DAY }

  def dispute_account(code, currency = 'usd')
    balance_of("platform:#{code}", currency)
  end

  def open_dispute(**)
    payment = captured_payment(**)
    clock.advance(7 * day)
    poller.poll
    payment
  end

  describe 'dispute.opened' do
    it 'records the dispute, takes the amount and the fee from available, and emits charge.dispute.created' do
      pi, reference = captured_payment
      expect(available).to eq(9_680)
      clock.advance(8 * day) # the poll is a day late; the ledger keeps the acquirer's time
      expect(poller.poll.processed).to eq(1)

      dispute = the_dispute
      expect(dispute).to have_attributes(payment_intent: pi, merchant_id: merchant.id, status: 'needs_response',
                                         amount: usd(10_000), fee: usd(1_500), reason: 'fraudulent',
                                         acquirer_reference: reference, created_at: Time.utc(2026, 3, 9, 9))
      # Available is carried negative (payouts are blocked meanwhile).
      expect([available, dispute_account('dispute_clearing'), dispute_account('dispute_fee_revenue')])
        .to eq([9_680 - 10_000 - 1_500, 10_000, 1_500])
      txn = app_db[:ledger_transactions].where(id: dispute.opened_transaction_id).first
      expect(txn).to include(flow_id: dispute.id, flow_type: 'dispute', effective_at: Time.utc(2026, 3, 9, 9),
                             description: "dispute #{dispute.id} opened on #{pi}")
      expect(Clearinghouse::Ledger::Invariants.check(app_db)).to be_empty
      expect(dispute_events.map { |e| [e['type'], e['merchant_id']] }).to eq([['charge.dispute.created', merchant.id]])
      expect(dispute_events.first['data']['object'])
        .to include('id' => dispute.id, 'object' => 'dispute', 'payment_intent' => pi, 'amount' => 10_000,
                    'currency' => 'usd', 'reason' => 'fraudulent', 'status' => 'needs_response')
    end

    it 'disputes the full captured amount even after a partial refund, as the network does' do
      pi, = captured_payment
      api_request(:post, '/v1/refunds', { payment_intent: pi, amount: 4_000 })
      clock.advance(7 * day)
      poller.poll
      expect(the_dispute.amount).to eq(usd(10_000))
      expect(available).to eq(9_680 - 4_000 - 10_000 - 1_500)
    end

    it 'prices the fee in the dispute currency' do
      open_dispute(amount: 5_000, currency: 'jpy')
      expect(the_dispute.fee).to eq(Clearinghouse::Money.of(2_200, 'jpy'))
      expect(dispute_account('dispute_fee_revenue', 'jpy')).to eq(2_200)
    end

    it 'stops the feed on a dispute for a payment we do not know, writing nothing' do
      acquirer_charge(payment_method: 'pm_card_disputeFraudulent')
      clock.advance(7 * day)
      expect { poller.poll }.to raise_error(Clearinghouse::Disputes::UnknownPaymentError, /matches no payment/)
      expect(app_db[:disputes].count + app_db[:processed_notifications].count).to eq(0)
      expect(dispute_events).to be_empty
    end

    it 'refuses a dispute in another currency than its payment' do
      pi, = captured_payment
      owner_db[:payment_intents].where(id: pi).update(currency: 'eur') # as if our record were wrong
      clock.advance(7 * day)
      expect { poller.poll }.to raise_error(Clearinghouse::Disputes::InconsistentNotificationError, /usd.*eur/)
    end

    it 'is idempotent when called directly with the same notification' do
      captured_payment
      clock.advance(7 * day)
      notification = client.notifications(after: '0').data.first
      first = service.opened(app_db, notification)
      expect(service.opened(app_db, notification).id).to eq(first.id)
      expect(app_db[:ledger_transactions].where(flow_id: first.id).count).to eq(1)
      expect(dispute_events.length).to eq(1)
    end

    it 'rejects a malformed notification' do
      _, reference = captured_payment
      bad = Clearinghouse::Acquirer::Notification.new(id: 'ntf_1', type: 'dispute.opened', created_at: clock.now,
                                                      cursor: '1', data: { 'dispute_id' => 'dsp_1',
                                                                           'acquirer_reference' => reference,
                                                                           'amount' => -5, 'currency' => 'usd' })
      expect { service.opened(app_db, bad) }.to raise_error(Clearinghouse::Disputes::InconsistentNotificationError,
                                                            /not positive/)
      expect { service.opened(app_db, bad.with(data: {})) }.to raise_error(/no dispute_id/)
    end
  end

  describe 'dispute.closed' do
    before { open_dispute }

    it 'returns the amount to the merchant on a win and keeps the fee' do
      clock.advance(3 * day)
      resolve_at_acquirer('won')
      poller.poll

      dispute = the_dispute
      expect(dispute).to have_attributes(status: 'won', closed_by: 'acquirer', closed_at: clock.now)
      expect(available).to eq(9_680 - 1_500)
      expect(dispute_account('dispute_clearing')).to eq(0) # the acquirer's two settlement lines are still to come
      expect(app_db[:ledger_transactions].where(id: dispute.won_transaction_id).get(:description))
        .to eq("dispute #{dispute.id} won on #{dispute.payment_intent}")
      expect(dispute_event_types).to eq(%w[charge.dispute.created charge.dispute.closed])
      expect(dispute_events.last['data']['object']).to include('status' => 'won')
    end

    it 'posts nothing more on a loss' do
      postings = app_db[:ledger_transactions].count
      resolve_at_acquirer('lost')
      poller.poll
      expect(the_dispute).to have_attributes(status: 'lost', closed_by: 'acquirer')
      expect(app_db[:ledger_transactions].count).to eq(postings)
      expect(dispute_events.last['data']['object']).to include('status' => 'lost')
    end

    it 'refuses a close for a dispute that was never opened here' do
      closed = Clearinghouse::Acquirer::Notification.new(id: 'ntf_2', type: 'dispute.closed', created_at: clock.now,
                                                         cursor: '9', data: { 'dispute_id' => 'dsp_nope',
                                                                              'outcome' => 'won' })
      expect { service.closed(app_db, closed) }.to raise_error(Clearinghouse::Disputes::NotFoundError)
      unknown = closed.with(data: { 'dispute_id' => the_dispute.acquirer_dispute_id, 'outcome' => 'drawn' })
      expect { service.closed(app_db, unknown) }.to raise_error(/unknown outcome drawn/)
    end

    it 'applies a win once when the same ruling arrives twice' do
      resolve_at_acquirer('won')
      poller.poll
      again = Clearinghouse::Acquirer::Notification.new(
        id: 'ntf_again', type: 'dispute.closed', created_at: clock.now, cursor: '9',
        data: { 'dispute_id' => the_dispute.acquirer_dispute_id, 'outcome' => 'won' }
      )
      service.closed(app_db, again)
      expect(app_db[:ledger_transactions].where(flow_id: the_dispute.id).count).to eq(2)
      expect(dispute_events.length).to eq(2)
      expect { service.closed(app_db, again.with(data: again.data.merge('outcome' => 'lost'))) }
        .to raise_error(/was won and is now reported lost/)
    end

    it 'refuses a ruling that contradicts an earlier one' do
      resolve_at_acquirer('lost')
      poller.poll
      flipped = Clearinghouse::Acquirer::Notification.new(
        id: 'ntf_3', type: 'dispute.closed', created_at: clock.now, cursor: '9',
        data: { 'dispute_id' => the_dispute.acquirer_dispute_id, 'outcome' => 'won' }
      )
      expect { service.closed(app_db, flipped) }.to raise_error(/was lost and is now reported won/)
    end
  end

  describe 'the merchant accepting the loss' do
    before { open_dispute }

    let(:accept) { -> { service.accept(app_db, merchant_id: merchant.id, id: the_dispute.id) } }

    it 'closes it lost with no posting, once' do
      postings = app_db[:ledger_transactions].count
      expect(accept.call).to have_attributes(status: 'lost', closed_by: 'merchant', closed_at: clock.now)
      expect(accept.call.status).to eq('lost')
      expect(app_db[:ledger_transactions].count).to eq(postings)
      expect(dispute_event_types).to eq(%w[charge.dispute.created charge.dispute.closed])
    end

    it 'ignores the acquirer confirming the loss afterwards' do
      accept.call
      resolve_at_acquirer('lost')
      poller.poll
      expect(the_dispute).to have_attributes(status: 'lost', closed_by: 'merchant')
      expect(dispute_events.length).to eq(2)
    end

    it 'still returns the money if the acquirer rules for the merchant anyway' do
      accept.call
      resolve_at_acquirer('won')
      poller.poll
      expect(the_dispute).to have_attributes(status: 'won', closed_by: 'acquirer')
      expect(available).to eq(9_680 - 1_500)
    end

    it 'cannot accept a dispute that was won, or one belonging to another merchant' do
      resolve_at_acquirer('won')
      poller.poll
      expect { accept.call }.to raise_error(Clearinghouse::Disputes::AlreadyClosedError)
      expect { service.accept(app_db, merchant_id: 'acct_other', id: the_dispute.id) }
        .to raise_error(Clearinghouse::Disputes::NotFoundError)
    end
  end

  describe Clearinghouse::Disputes::FeePolicy do
    it 'prices every currency Clearinghouse supports' do
      policy = described_class.new
      Clearinghouse::Currency::EXPONENTS.each_key do |currency|
        expect(policy.fee_for(currency.upcase)).to have_attributes(currency: currency, amount: be_positive)
      end
    end

    it 'refuses to charge a currency it has no price for' do
      expect { described_class.new(fees: { 'usd' => 1_500 }).fee_for('jpy') }
        .to raise_error(described_class::UnpricedCurrencyError, /jpy/)
    end
  end
end
