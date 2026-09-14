# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Balances::NullEventSink do
  let(:clock) { Clearinghouse::Clock::Test.new }
  let(:db) { Sequel.mock }

  it 'accepts the event types this area emits and drops them' do
    Clearinghouse::Balances::EVENT_TYPES.each do |type|
      expect { described_class.new.emit!(db, merchant_id: 'acct_1', type: type, object: {}, clock: clock) }
        .not_to raise_error
    end
  end

  it 'refuses a type it does not know, so a typo fails here and not when the outbox lands' do
    expect { described_class.new.emit!(db, merchant_id: 'acct_1', type: 'payout.sent', object: {}, clock: clock) }
      .to raise_error(ArgumentError, /payout.sent/)
  end
end
