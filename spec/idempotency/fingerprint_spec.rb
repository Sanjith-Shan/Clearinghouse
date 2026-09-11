# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Idempotency::Fingerprint do
  def fp(params, method: 'POST', path: '/v1/payment_intents/pi_1/confirm')
    described_class.compute(method: method, path: path, params: params)
  end

  it 'is SHA-256 hex of the canonical JSON of [method, path, params]' do
    canonical = '["POST","/v1/x",{"a":"1","b":{"c":null,"d":["2","true"]}}]'
    expect(described_class.canonical_json(['POST', '/v1/x', { 'b' => { 'd' => [2, true], 'c' => nil }, 'a' => 1 }]))
      .to eq(canonical)
    expect(fp({ 'b' => { 'd' => [2, true], 'c' => nil }, 'a' => 1 }, path: '/v1/x'))
      .to eq(Digest::SHA256.hexdigest(canonical))
  end

  it 'ignores key order at every depth' do
    expect(fp({ 'a' => '1',
                'm' => { 'x' => '1', 'y' => '2' } })).to eq(fp({ 'm' => { 'y' => '2', 'x' => '1' }, 'a' => '1' }))
  end

  it 'treats a form body and the same request as JSON alike' do
    form = { 'amount' => '2000', 'capture' => 'true', 'expand' => ['latest_charge'] }
    json = { 'amount' => 2000, 'capture' => true, 'expand' => ['latest_charge'] }
    expect(fp(form)).to eq(fp(json))
  end

  it 'tells apart everything that changes the request' do
    variants = [fp({ 'amount' => '2000' }), fp({ 'amount' => '2001' }),
                fp({ 'amount' => '2000', 'expand' => ['latest_charge'] }), fp({ 'amount' => '2000' }, method: 'GET'),
                fp({ 'amount' => '2000' }, path: '/v1/payment_intents/pi_2/confirm'),
                fp({ 'amount' => nil }), fp({ 'amount' => '' }), fp({})]
    expect(variants.uniq.length).to eq(variants.length)
  end

  it 'keeps array order, which is meaningful' do
    expect(fp({ 'expand' => %w[a b] })).not_to eq(fp({ 'expand' => %w[b a] }))
  end

  it 'uppercases the method' do
    expect(fp({}, method: 'post')).to eq(fp({}, method: 'POST'))
  end

  it 'writes a float the way Ruby prints it, and refuses anything JSON could not have sent' do
    expect(described_class.canonical(1.5)).to eq('1.5')
    expect { described_class.canonical(Object.new) }.to raise_error(ArgumentError, /cannot fingerprint/)
  end
end
