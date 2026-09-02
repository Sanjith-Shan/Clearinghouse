# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Api::Auth do
  describe '.key_from_header' do
    it 'reads Bearer and Basic, case-insensitively' do
      expect(described_class.key_from_header('Bearer sk_test_a')).to eq('sk_test_a')
      expect(described_class.key_from_header('bearer   sk_test_a')).to eq('sk_test_a')
      expect(described_class.key_from_header("Basic #{Base64.strict_encode64('sk_test_a:')}")).to eq('sk_test_a')
    end

    it 'returns nil for nothing, an unknown scheme or bad base64' do
      expect(described_class.key_from_header(nil)).to be_nil
      expect(described_class.key_from_header('  ')).to be_nil
      expect(described_class.key_from_header('Digest abc')).to be_nil
      expect(described_class.key_from_header('Basic !!!')).to be_nil
      expect(described_class.key_from_header('Basic')).to be_nil
    end
  end

  it 'redacts all but the prefix and the last four characters' do
    expect(described_class.redact('sk_test_abcdefghijklmnopqrstuvwx')).to eq('sk_test_****uvwx')
    expect(described_class.redact('short')).to eq('****')
  end
end
