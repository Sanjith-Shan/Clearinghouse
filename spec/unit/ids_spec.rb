# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Ids do
  it 'is the prefix, an underscore and 24 base62 characters' do
    id = described_class.generate('pi')
    expect(id).to match(/\Api_[A-Za-z0-9]{24}\z/)
    expect(described_class.valid?(id, 'pi')).to be(true)
  end

  it 'handles a prefix that itself has an underscore' do
    expect(described_class.generate('sk_test')).to match(/\Ask_test_[A-Za-z0-9]{24}\z/)
  end

  it 'registers every prefix the interfaces doc names as a flow or object id' do
    expect(described_class::PREFIXES.values).to include('pi', 're', 'dp', 'po', 'evt', 'we', 'acct', 'req', 'txn')
  end

  it 'never gives two object types the same prefix' do
    expect(described_class::PREFIXES.values.uniq.size).to eq(described_class::PREFIXES.size)
  end

  it 'refuses an unregistered prefix' do
    expect { described_class.generate('xx') }.to raise_error(described_class::UnknownPrefixError)
  end

  it 'does not repeat across many draws' do
    ids = Array.new(10_000) { described_class.generate('evt') }
    expect(ids.uniq.size).to eq(10_000)
  end

  it 'uses the whole alphabet' do
    chars = Array.new(2_000) { described_class.generate('re').delete_prefix('re_') }.join.chars.uniq
    expect(chars.size).to eq(62)
  end

  it 'rejects ids of the wrong shape' do
    expect(described_class.valid?('pi_short', 'pi')).to be(false)
    expect(described_class.valid?("re_#{'a' * 24}", 'pi')).to be(false)
    expect(described_class.valid?("pi_#{'a' * 23}!", 'pi')).to be(false)
    expect(described_class.valid?(nil, 'pi')).to be(false)
  end
end
