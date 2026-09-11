# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Idempotency::Serializable, :db do
  let(:sleeps) { [] }
  let(:sleeper) { ->(seconds) { sleeps << seconds } }
  let(:policy) { described_class::Policy.new(attempts: 4, base_delay: 0.01, max_delay: 0.03) }

  def run(&)
    described_class.transaction(app_db, policy: policy, sleeper: sleeper, random: Random.new(7), &)
  end

  it 'runs the block in a SERIALIZABLE transaction and returns its value' do
    level = run { app_db.fetch('SHOW transaction_isolation').get(:transaction_isolation) }
    expect(level).to eq('serializable')
  end

  it 'retries a serialization failure with jittered, capped, growing backoff, then succeeds' do
    calls = 0
    before = described_class.retries
    value = run do
      calls += 1
      raise Sequel::SerializationFailure, 'could not serialize access' if calls < 4

      :done
    end
    expect([value, calls, sleeps.length, described_class.retries - before]).to eq([:done, 4, 3, 3])
    caps = [0.02, 0.03, 0.03] # min(max_delay, base * 2^attempt)
    sleeps.zip(caps).each { |slept, cap| expect(slept).to be_between(0, cap) }
  end

  it 'gives up after the last attempt with the cause' do
    expect { run { raise Sequel::SerializationFailure, 'deadlock detected' } }
      .to raise_error(described_class::ExhaustedError, /after 4 attempts: deadlock detected/) { |e|
        expect(e.attempts).to eq(4)
      }
    expect(sleeps.length).to eq(3)
  end

  it 'does not retry other errors' do
    calls = 0
    expect do
      run do
        calls += 1
        raise ArgumentError, 'bug'
      end
    end.to raise_error(ArgumentError)
    expect(calls).to eq(1)
  end

  it 'refuses to nest, where isolation would be ignored and a retry would redo half the work' do
    app_db.transaction do
      expect { run { 1 } }.to raise_error(Clearinghouse::Error, /cannot run inside another transaction/)
    end
  end

  # Write skew: each transaction reads the total and inserts if there is room.
  # Under READ COMMITTED both would insert. SERIALIZABLE rolls one back, the
  # retry sees the other's row, and the limit holds.
  it 'turns a real write-skew conflict into a retry that sees the winner' do
    ToyFlow.create_table!
    barrier = Queue.new
    go = Queue.new
    results = Array.new(2) do |i|
      Thread.new do
        first = true
        described_class.transaction(app_db, policy: described_class::Policy.new(attempts: 5, base_delay: 0.001),
                                            sleeper: ->(_) {}) do
          count = app_db[:idem_spec_log].where(step: 'slot').count
          if first
            first = false
            barrier << i
            go.pop
          end
          next :full if count >= 1

          app_db[:idem_spec_log].insert(key_id: i, step: 'slot')
          :inserted
        end
      end
    end
    2.times { barrier.pop }
    2.times { go << true }
    expect(results.map(&:value).sort).to eq(%i[full inserted])
    expect(app_db[:idem_spec_log].where(step: 'slot').count).to eq(1)
  end
end
