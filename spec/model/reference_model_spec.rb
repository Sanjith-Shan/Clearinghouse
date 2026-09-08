# typed: false
# frozen_string_literal: true

require_relative 'model_helper'

# The reference model is the specification the real system is held to, so its
# policies are pinned here one by one against docs/design/ledger.md.
RSpec.describe Clearinghouse::Testing::Model::ReferenceModel, :model do
  subject(:model) { described_class.new }

  def bal(code, currency = 'usd')
    model.balance(code, currency)
  end

  def pay(name, amount, card: 'pm_card_visa', **opts)
    model.apply(intent_cmd(name, amount, **opts))
    model.confirm(intent: name, payment_method: card)
  end

  def advance_days(days)
    model.advance_clock(hours: days * 24)
  end

  before { model.apply(merchant_cmd) }

  it 'books a $100 capture as the money-flow table does, fee 2.9% + 30c' do
    expect(pay('pi_1', 10_000).fields).to include('status' => 'succeeded', 'amount_received' => 10_000)
    expect(bal('platform:processor_receivable')).to eq(10_000)
    expect(bal('merchant:m1:pending')).to eq(9680)
    expect(bal('platform:fee_revenue')).to eq(320)
    expect(model.open_flows).to eq('pi_1' => { %w[platform:processor_receivable usd] => 10_000 })
  end

  it 'rounds the percentage part of the fee half to even' do
    pay('pi_1', 500)  # 2.9% of 500 is 14.5, which rounds to 14
    pay('pi_2', 1500) # 43.5 rounds to 44
    expect(bal('platform:fee_revenue')).to eq(14 + 30 + 44 + 30)
  end

  it 'settles net of the acquirer fee on the settlement date, which clears the receivable' do
    pay('pi_1', 10_000)
    model.settle
    expect(bal('platform:cash')).to eq(0)
    advance_days(2)
    model.settle
    expect(bal('platform:cash')).to eq(9840)
    expect(bal('platform:processing_expense')).to eq(160)
    expect(model.open_flows).to eq({})
    expect(model.flow_complete?('pi_1')).to be(true)
  end

  it 'puts lines from a skipped day in the next file, and a second request for a day changes nothing' do
    pay('pi_1', 10_000)
    advance_days(5)
    model.settle
    model.settle
    expect(bal('platform:cash')).to eq(9840)
  end

  it 'makes funds available two days after capture, not before' do
    pay('pi_1', 10_000)
    model.advance_clock(hours: 47)
    model.availability_sweep
    expect(bal('merchant:m1:available')).to eq(0)
    model.advance_clock(hours: 1)
    model.availability_sweep
    model.availability_sweep
    expect(bal('merchant:m1:available')).to eq(9680)
    expect(bal('merchant:m1:pending')).to eq(0)
  end

  it 'does not return the fee on a refund, and refunds from available even into the negative' do
    pay('pi_1', 10_000)
    expect(model.refund(refund: 're_1', intent: 'pi_1', amount: 4000)).to eq(success(amount: 4000))
    expect(bal('merchant:m1:available')).to eq(-4000)
    expect(bal('platform:fee_revenue')).to eq(320)
    expect(model.refund(refund: 're_2', intent: 'pi_1').fields).to eq('amount' => 6000)
    expect(model.refund(refund: 're_3', intent: 'pi_1').code).to eq('charge_already_refunded')
  end

  it 'refuses refunds past the captured amount and on payments that did not succeed' do
    pay('pi_1', 10_000, capture_method: 'manual')
    expect(model.refund(refund: 're_1', intent: 'pi_1').code).to eq('payment_intent_unexpected_state')
    model.capture(intent: 'pi_1', amount: 6000)
    expect(model.refund(refund: 're_1', intent: 'pi_1', amount: 6001).code).to eq('amount_too_large')
    expect(model.intents.fetch('pi_1').refunded).to eq(0)
  end

  it 'blocks payouts while available is zero or negative and never pays out pending funds' do
    pay('pi_1', 10_000)
    expect(model.payout(payout: 'po_1', merchant: 'm1', currency: 'usd').code).to eq('balance_insufficient')
    advance_days(2)
    model.availability_sweep
    model.refund(refund: 're_1', intent: 'pi_1', amount: 9680)
    expect(model.payout(payout: 'po_1', merchant: 'm1', currency: 'usd').code).to eq('balance_insufficient')
    expect(model.payouts).to be_empty
  end

  it 'pays out at most what is available, and a payout ending in 13 fails and comes back' do
    pay('pi_1', 10_000)
    advance_days(2)
    model.availability_sweep
    expect(model.payout(payout: 'po_1', merchant: 'm1', currency: 'usd', amount: 9681).code)
      .to eq('balance_insufficient')
    expect(model.payout(payout: 'po_1', merchant: 'm1', currency: 'usd', amount: 1013)).to be_ok
    expect(bal('platform:payout_clearing')).to eq(1013)
    advance_days(1)
    expect(model.payouts.fetch('po_1').status).to eq('failed')
    expect(bal('merchant:m1:available')).to eq(9680)
    expect(model.open_flows).not_to have_key('po_1')
  end

  it 'opens a dispute 7 days after capture, takes amount and fee, and carries the negative balance' do
    pay('pi_1', 10_000, card: 'pm_card_disputeFraudulent')
    advance_days(6)
    expect(model.resolve_dispute(intent: 'pi_1', outcome: 'won').code).to eq('dispute_not_open')
    advance_days(1)
    expect(model.disputes.fetch('dp_1').status).to eq('open')
    expect(bal('merchant:m1:available')).to eq(-11_500)
    expect(bal('platform:dispute_fee_revenue')).to eq(1500)
    expect(model.refund(refund: 're_1', intent: 'pi_1').code).to eq('charge_disputed')
    model.availability_sweep
    expect(bal('merchant:m1:available')).to eq(9680 - 11_500)
    expect(model.payout(payout: 'po_1', merchant: 'm1', currency: 'usd').code).to eq('balance_insufficient')
  end

  it 'refuses a refund once the dispute has opened at the acquirer, before the notification is processed' do
    pay('pi_1', 10_000, card: 'pm_card_disputeFraudulent')
    model.advance_clock(hours: (7 * 24) - 1)
    expect(model.refund(refund: 're_1', intent: 'pi_1', amount: 100)).to be_ok
    model.advance_clock(hours: 1)
    expect(model.refund(refund: 're_2', intent: 'pi_1', amount: 100).code).to eq('charge_disputed')
  end

  it 'returns the amount but keeps the fee when a dispute is won, and clears once both lines settle' do
    pay('pi_1', 10_000, card: 'pm_card_disputeFraudulent')
    advance_days(7)
    model.resolve_dispute(intent: 'pi_1', outcome: 'won')
    expect(bal('merchant:m1:available')).to eq(-1500)
    expect(model.resolve_dispute(intent: 'pi_1', outcome: 'lost').code).to eq('dispute_already_closed')
    expect(model.flow_complete?('dp_1')).to be(false)
    advance_days(2)
    model.settle
    expect(model.open_flows).not_to have_key('dp_1')
    expect(model.flow_complete?('dp_1')).to be(true)
    expect(bal('platform:cash')).to eq(9840) # the dispute went out and came back
  end

  it 'keeps a lost dispute open until the acquirer debit settles' do
    pay('pi_1', 10_000, card: 'pm_card_disputeFraudulent')
    advance_days(7)
    model.resolve_dispute(intent: 'pi_1', outcome: 'lost')
    expect(model.open_flows.fetch('dp_1')).to eq(%w[platform:dispute_clearing usd] => 10_000)
    advance_days(2)
    model.settle
    expect(model.flow_complete?('dp_1')).to be(true)
    expect(bal('platform:cash')).to eq(9840 - 10_000)
  end

  it 'captures partially, releasing the rest, and refuses captures past the authorization or below the minimum' do
    model.apply(intent_cmd('pi_1', 10_000, capture_method: 'manual'))
    expect(model.confirm(intent: 'pi_1', payment_method: 'pm_card_visa').fields)
      .to eq('status' => 'requires_capture', 'amount_received' => 0)
    expect(model.capture(intent: 'pi_1', amount: 10_001).code).to eq('amount_too_large')
    expect(model.capture(intent: 'pi_1', amount: 49).code).to eq('amount_too_small')
    expect(model.capture(intent: 'pi_1', amount: 2500).fields).to eq('status' => 'succeeded', 'amount_received' => 2500)
    expect(model.capture(intent: 'pi_1').code).to eq('payment_intent_unexpected_state')
    expect(bal('platform:processor_receivable')).to eq(2500)
  end

  it 'moves a declined payment back to requires_payment_method, and a retry with a good card succeeds' do
    model.apply(intent_cmd('pi_1', 10_000))
    expect(model.confirm(intent: 'pi_1', payment_method: 'pm_card_insufficientFunds'))
      .to eq(error('card_declined', decline_code: 'insufficient_funds'))
    expect(model.intents.fetch('pi_1').status).to eq('requires_payment_method')
    expect(model.confirm(intent: 'pi_1', payment_method: 'pm_card_timeout')).to be_ok
    expect(model.confirm(intent: 'pi_1', payment_method: 'pm_card_visa').code).to eq('payment_intent_unexpected_state')
  end

  it 'cancels only before capture, and moves no money' do
    model.apply(intent_cmd('pi_1', 10_000, capture_method: 'manual'))
    model.confirm(intent: 'pi_1', payment_method: 'pm_card_visa')
    expect(model.cancel(intent: 'pi_1').fields).to include('status' => 'canceled')
    expect(model.cancel(intent: 'pi_1').code).to eq('payment_intent_unexpected_state')
    expect(model.capture(intent: 'pi_1').code).to eq('payment_intent_unexpected_state')
    expect(model.snapshot.balances).to eq({})
  end

  it 'answers resource_missing for objects that do not exist' do
    expect(model.confirm(intent: 'pi_404', payment_method: 'pm_card_visa').code).to eq('resource_missing')
    expect(model.apply(intent_cmd('pi_1', 100, merchant: 'm9')).code).to eq('resource_missing')
    expect(model.resolve_dispute(intent: 'pi_404', outcome: 'won').code).to eq('resource_missing')
  end

  it 'keeps currencies apart, including zero- and three-decimal ones' do
    pay('pi_1', 1000, currency: 'jpy')
    pay('pi_2', 1000, currency: 'kwd')
    expect(bal('platform:fee_revenue', 'jpy')).to eq(29)
    expect(bal('platform:fee_revenue', 'kwd')).to eq(29)
    expect(bal('platform:fee_revenue', 'usd')).to eq(0)
  end

  it 'names the next free object of each kind without consuming it' do
    expect(model.next_name(:intent)).to eq('pi_1')
    expect(model.next_name(:intent)).to eq('pi_1')
    model.apply(intent_cmd('pi_1', 100))
    expect([model.next_name(:intent), model.next_name(:merchant)]).to eq(%w[pi_2 m2])
  end
end
