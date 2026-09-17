# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Routes::ReconciliationExceptions do
  include_context 'with the api app'
  include_context 'with a merchant'

  let(:db) { ApiSpecHelpers.db }
  let(:operator) { { 'HTTP_AUTHORIZATION' => 'Bearer admin_spec_token' } }
  let(:exceptions) { Clearinghouse::Reconciliation::Exceptions }

  # A payment whose settlement came up 5 cents short, and the exception for it.
  def short_settlement
    flows = Clearinghouse::Ledger::Flows
    usd = ->(n) { Clearinghouse::Money.of(n, 'usd') }
    Clearinghouse::Ledger.post!(db, flow_type: 'payment', flow_id: 'pi_1', description: 'capture',
                                    effective_at: clock.now,
                                    entries: flows.capture(merchant_id: merchant.id, gross: usd[1_000], fee: usd[59]))
    Clearinghouse::Ledger.post!(db, flow_type: 'payment', flow_id: 'pi_1', description: 'settlement of pi_1',
                                    effective_at: clock.now,
                                    entries: flows.settlement(gross: usd[995], acquirer_fee: usd[25]))
    exceptions.create!(db, exceptions::Draft.new(
                             reason: 'amount_mismatch', line_type: 'capture', currency: 'usd', detail: 'short',
                             flow_id: 'pi_1', flow_type: 'payment', merchant_id: merchant.id, expected_amount: 1_000,
                             expected_fee: 25, clearing_account: 'platform:processor_receivable',
                             unexplained_amount: 5, acquirer_reference: 'acq_1', operation_id: 'op_1'
                           ), now: clock.now)
  end

  it 'needs the admin token, not a merchant key' do
    get '/v1/reconciliation_exceptions', {}, auth
    expect(last_response.status).to eq(401)
    expect(json_body['error']).to include('code' => 'admin_token_invalid')
    get '/v1/reconciliation_exceptions'
    expect(last_response.status).to eq(401)
  end

  it 'lists, reads and resolves with a write-off' do
    id = short_settlement
    get '/v1/reconciliation_exceptions', { status: 'open', reason: 'amount_mismatch' }, operator
    expect(json_body).to include('object' => 'list', 'has_more' => false)
    expect(json_body['data'].map { |x| x['id'] }).to eq([id])

    get "/v1/reconciliation_exceptions/#{id}", {}, operator
    expect(json_body).to include('object' => 'reconciliation_exception', 'reason' => 'amount_mismatch',
                                 'status' => 'open', 'flow' => 'pi_1', 'expected' => { 'amount' => 1_000, 'fee' => 25 },
                                 'unexplained_amount' => 5, 'settlement_line' => nil, 'resolution' => nil)

    post "/v1/reconciliation_exceptions/#{id}/resolve", { note: 'acquirer will not pay', action: 'write_off' }, operator
    expect(last_response.status).to eq(200)
    expect(json_body['resolution']).to include('action' => 'write_off', 'note' => 'acquirer will not pay',
                                               'resolved' => clock.now.to_i)
    expect(json_body['resolution']['ledger_transaction']).to be_a(Integer)
    expect(Clearinghouse::Ledger::Clearing.report(db, as_of: clock.now, slas: {}).open_flows).to be_empty
  end

  it 'maps resolution problems to typed errors' do
    id = short_settlement
    post "/v1/reconciliation_exceptions/#{id}/resolve", { action: 'none' }, operator
    expect(json_body['error']).to include('code' => 'parameter_missing', 'param' => 'note')

    post "/v1/reconciliation_exceptions/#{id}/resolve", { note: 'x', action: 'reverse', ledger_transaction: 99_999 },
         operator
    expect(json_body['error']).to include('code' => 'resolution_invalid')

    post "/v1/reconciliation_exceptions/#{id}/resolve", { note: 'x' }, operator
    expect(json_body['resolution']).to include('action' => 'none')
    post "/v1/reconciliation_exceptions/#{id}/resolve", { note: 'x' }, operator
    expect(json_body['error']).to include('code' => 'reconciliation_exception_resolved')

    post '/v1/reconciliation_exceptions/rex_nope/resolve', { note: 'x' }, operator
    expect(last_response.status).to eq(404)
  end

  it 'refuses unknown ids and filters' do
    get '/v1/reconciliation_exceptions/rex_nope', {}, operator
    expect(last_response.status).to eq(404)
    get '/v1/reconciliation_exceptions', { reason: 'bogus' }, operator
    expect(json_body['error']).to include('code' => 'parameter_invalid', 'param' => 'reason')
    get '/v1/reconciliation_exceptions', { starting_after: 'rex_nope' }, operator
    expect(json_body['error']).to include('code' => 'resource_missing', 'param' => 'starting_after')
  end
end
