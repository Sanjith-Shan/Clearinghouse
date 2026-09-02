# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Merchants do
  let(:db) { ApiSpecHelpers.db }
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 2)) }

  before { ApiSpecHelpers.reset_merchants! }

  it 'round-trips a merchant through the database' do
    fees = Clearinghouse::FeeSchedule.new(rate_scaled: 123_456, fixed_minor: { 'eur' => 25 })
    created, key = described_class.create(db, clock: clock, name: 'A', api_version: '2026-06-01', fee_schedule: fees,
                                              payout_interval: 'manual', payout_delay_days: 0)
    expect(described_class.authenticate(db, key).serialize).to eq(created.serialize)
    expect(described_class.find(db, created.id).serialize).to eq(created.serialize)
    expect(created.created_at).to eq(Time.utc(2026, 9, 2))
    expect(created.secret_key_last4).to eq(key[-4..])
  end

  it 'finds nothing for an unknown key or id' do
    described_class.create(db, clock: clock, name: 'A', api_version: '2026-09-01')
    expect(described_class.authenticate(db, Clearinghouse::Ids.generate('sk_test'))).to be_nil
    expect(described_class.find(db, 'acct_nope')).to be_nil
  end

  it 'gives every merchant a different key' do
    keys = Array.new(3) { described_class.create(db, clock: clock, name: 'A', api_version: '2026-09-01').last }
    expect(keys.uniq.size).to eq(3)
  end

  describe 'the table' do
    it 'refuses a key digest that is not a SHA-256 hex digest' do
      expect do
        db[:merchants].insert(id: Clearinghouse::Ids.generate('acct'), name: 'x', secret_key_hash: 'plaintext',
                              secret_key_last4: 'abcd', api_version: '2026-09-01', created_at: Time.now.utc)
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'does not let the app role update or delete merchants' do
      created, = described_class.create(db, clock: clock, name: 'A', api_version: '2026-09-01')
      expect do
        db[:merchants].where(id: created.id).update(name: 'B')
      end.to raise_error(Sequel::DatabaseError, /permission denied/)
      expect { db[:merchants].where(id: created.id).delete }.to raise_error(Sequel::DatabaseError, /permission denied/)
    end
  end

  describe 'percentages' do
    {
      '2.9' => 290_000, '0' => 0, '1.75' => 175_000, '0.00001' => 1, '100' => 10_000_000, '12.34567' => 1_234_567
    }.each do |text, scaled|
      it "parses #{text}% exactly and prints it back" do
        expect(described_class.parse_percent(text)).to eq(scaled)
        expect(described_class.percent_string(scaled)).to eq(text)
      end
    end

    %w[2.9.1 -1 1e2 100.00001 .5 2.123456].each do |text|
      it "rejects #{text.inspect}" do
        expect { described_class.parse_percent(text) }.to raise_error(ArgumentError)
      end
    end
  end
end
