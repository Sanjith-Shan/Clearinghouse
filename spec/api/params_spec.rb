# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Params do
  include_context 'with the api app'

  let(:app_class) do
    Class.new(Clearinghouse::Api::App) do
      post '/echo' do
        p = api_params.permit!('amount', 'currency', 'capture', 'description',
                               { 'shipping' => ['name', { 'address' => %w[city] }] })
        respond({ 'amount' => p.integer('amount', required: true, min: 1),
                  'currency' => p.enum('currency', %w[usd jpy], required: true),
                  'capture' => p.boolean('capture'),
                  'description' => p.string('description', max_length: 10),
                  'shipping' => p['shipping'],
                  'metadata' => p.metadata,
                  'expand' => p.expand })
      end
    end
  end

  def form(body)
    post '/echo', body, { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
  end

  def json(body)
    post '/echo', JSON.generate(body), { 'CONTENT_TYPE' => 'application/json' }
  end

  def error
    json_body.fetch('error')
  end

  it 'reads form bodies with Stripe-style brackets and coerces strings' do
    form('amount=2000&currency=usd&capture=false&metadata[order_id]=6735&metadata[note]=gift&expand[]=payment_method' \
         '&shipping[name]=Jo&shipping[address][city]=Oslo')
    expect(last_response.status).to eq(200)
    expect(json_body).to eq('amount' => 2000, 'currency' => 'usd', 'capture' => false, 'description' => nil,
                            'shipping' => { 'name' => 'Jo', 'address' => { 'city' => 'Oslo' } },
                            'metadata' => { 'order_id' => '6735', 'note' => 'gift' }, 'expand' => ['payment_method'])
  end

  it 'reads JSON bodies into the same shape' do
    json(amount: 2000, currency: 'usd', capture: false, metadata: { order_id: '6735' }, expand: ['payment_method'])
    expect(json_body).to include('amount' => 2000, 'capture' => false, 'metadata' => { 'order_id' => '6735' },
                                 'expand' => ['payment_method'])
  end

  it 'reads the query string too' do
    post '/echo?amount=5&currency=jpy'
    expect(json_body).to include('amount' => 5, 'currency' => 'jpy')
  end

  it 'accepts indexed expand params' do
    form('amount=1&currency=usd&expand[1]=b&expand[0]=a')
    expect(json_body['expand']).to eq(%w[a b])
  end

  it 'rejects an unknown parameter and names it' do
    form('amount=1&currency=usd&amuont=2')
    expect(last_response.status).to eq(400)
    expect(error).to include('code' => 'parameter_unknown', 'param' => 'amuont',
                             'message' => 'Received unknown parameter: amuont')
  end

  it 'names an unknown nested parameter with brackets' do
    form('amount=1&currency=usd&shipping[address][town]=x')
    expect(error).to include('code' => 'parameter_unknown', 'param' => 'shipping[address][town]')
  end

  it 'requires nested objects to be objects' do
    json(amount: 1, currency: 'usd', shipping: 'Jo')
    expect(error).to include('code' => 'parameter_invalid', 'param' => 'shipping')
  end

  it 'reports a missing required parameter' do
    form('currency=usd')
    expect(error).to include('code' => 'parameter_missing', 'param' => 'amount')
  end

  it 'treats an empty form value as missing' do
    form('amount=&currency=usd')
    expect(error).to include('code' => 'parameter_missing', 'param' => 'amount')
  end

  [['12.5', 'must be an integer.'], ['1e3', 'must be an integer.'],
   ['0', 'must be at least 1.']].each do |value, detail|
    it "rejects amount=#{value}" do
      form("amount=#{value}&currency=usd")
      expect(error).to include('code' => 'parameter_invalid', 'param' => 'amount',
                               'message' => "Invalid amount: #{detail}")
    end
  end

  it 'rejects a float amount in JSON' do
    json(amount: 20.5, currency: 'usd')
    expect(error).to include('param' => 'amount', 'code' => 'parameter_invalid')
  end

  it 'rejects a value outside an enum' do
    form('amount=1&currency=eur')
    expect(error).to include('param' => 'currency', 'message' => 'Invalid currency: must be one of usd, jpy.')
  end

  it 'rejects a boolean that is not true or false' do
    form('amount=1&currency=usd&capture=yes')
    expect(error).to include('param' => 'capture')
  end

  it 'rejects an overlong string' do
    form('amount=1&currency=usd&description=12345678901')
    expect(error).to include('param' => 'description')
  end

  it 'enforces metadata limits per key' do
    form("amount=1&currency=usd&metadata[#{'k' * 41}]=v")
    expect(error).to include('param' => "metadata[#{'k' * 41}]")
    form("amount=1&currency=usd&metadata[k]=#{'v' * 501}")
    expect(error).to include('param' => 'metadata[k]')
  end

  it 'caps metadata at 50 keys' do
    form(['amount=1', 'currency=usd', *Array.new(51) { |i| "metadata[k#{i}]=v" }].join('&'))
    expect(error).to include('param' => 'metadata')
  end

  it 'rejects expand paths deeper than four levels' do
    form('amount=1&currency=usd&expand[]=a.b.c.d.e')
    expect(error).to include('param' => 'expand')
  end

  it 'rejects malformed JSON' do
    post '/echo', '{"amount":', { 'CONTENT_TYPE' => 'application/json' }
    expect(last_response.status).to eq(400)
    expect(error).to include('type' => 'invalid_request_error', 'code' => 'body_invalid')
  end

  it 'rejects a JSON body that is not an object' do
    post '/echo', '[1,2]', { 'CONTENT_TYPE' => 'application/json' }
    expect(error).to include('code' => 'body_invalid')
  end

  it 'rejects an unsupported content type' do
    post '/echo', '<xml/>', { 'CONTENT_TYPE' => 'application/xml' }
    expect(error).to include('code' => 'body_invalid')
  end

  it 'rejects form parameters whose nesting conflicts' do
    form('amount=1&amount[x]=2&currency=usd')
    expect(last_response.status).to eq(400)
    expect(error).to include('code' => 'body_invalid')
    expect(error['message']).not_to include('&#')
  end
end
