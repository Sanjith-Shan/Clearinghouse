# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Idempotency::Turnstile, :db do
  let(:serializable) { Clearinghouse::Idempotency::Serializable }
  # One attempt: any serialization failure at all fails the transaction.
  let(:no_retries) { serializable::Policy.new(attempts: 1) }

  before { ToyFlow.create_table! }

  # The write skew serializable_spec.rb shows SERIALIZABLE rolling back, eight
  # at once: each reads the count, dawdles, and inserts the next number. Through
  # the turnstile they take turns before their snapshots, so not one of them
  # conflicts, and each sees every insert before it.
  it 'makes SERIALIZABLE transactions on one hot object queue instead of aborting' do
    gate = Queue.new
    threads = Array.new(8) do |i|
      Thread.new do
        gate.pop
        described_class.through(app_db, 'spec:counter') do
          serializable.transaction(app_db, policy: no_retries) do
            seen = app_db[:idem_spec_log].where(step: 'turn').count
            sleep 0.01
            app_db[:idem_spec_log].insert(key_id: i, step: 'turn', detail: seen.to_s)
          end
        end
      end
    end
    8.times { gate << :go }
    threads.each(&:join)
    expect(app_db[:idem_spec_log].where(step: 'turn').select_map(:detail).map(&:to_i).sort).to eq((0..7).to_a)
  end

  it 'lets different objects through at the same time' do
    inside = Queue.new
    release = Queue.new
    other = Thread.new do
      described_class.through(app_db, 'spec:a') do
        inside << :a
        release.pop
      end
    end
    inside.pop
    # 'spec:a' is held; 'spec:b' must not wait for it.
    expect(described_class.through(app_db, 'spec:b') { :b }).to eq(:b)
    release << :go
    other.join
  end

  it 'releases the lock when the block raises, and refuses to run inside a transaction' do
    expect { described_class.through(app_db, 'spec:c') { raise ArgumentError, 'boom' } }.to raise_error(ArgumentError)
    expect(Thread.new { described_class.through(app_db, 'spec:c') { :free } }.value).to eq(:free)
    app_db.transaction do
      expect { described_class.through(app_db, 'spec:c') { 1 } }.to raise_error(Clearinghouse::Error, /before/)
    end
  end
end
