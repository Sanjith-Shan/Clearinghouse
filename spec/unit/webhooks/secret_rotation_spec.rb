# typed: false
# frozen_string_literal: true

require 'base64'

RSpec.describe Clearinghouse::Webhooks::SecretRotation do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1)) }
  let(:rotation) { described_class.new(current: 'whsec_one') }

  it 'signs with only the current secret when nothing is rotating' do
    expect(rotation.active_secrets(now: clock.now)).to eq(['whsec_one'])
  end

  it 'signs with both secrets, current first, until the overlap ends' do
    rotated = rotation.rotate(new_secret: 'whsec_two', now: clock.now, overlap: 3600)
    expect(rotated.active_secrets(now: clock.now)).to eq(%w[whsec_two whsec_one])
    clock.advance(3599)
    expect(rotated.active_secrets(now: clock.now)).to eq(%w[whsec_two whsec_one])
    clock.advance(1)
    expect(rotated.active_secrets(now: clock.now)).to eq(['whsec_two'])
  end

  it 'drops the old secret at once with a zero overlap' do
    rotated = rotation.rotate(new_secret: 'whsec_two', now: clock.now, overlap: 0)
    expect(rotated.previous).to be_nil
    expect(rotated.active_secrets(now: clock.now)).to eq(['whsec_two'])
  end

  it 'keeps at most two secrets: rotating mid-window forgets the oldest' do
    once = rotation.rotate(new_secret: 'whsec_two', now: clock.now, overlap: 3600)
    twice = once.rotate(new_secret: 'whsec_three', now: clock.now + 60, overlap: 3600)
    expect(twice.active_secrets(now: clock.now + 60)).to eq(%w[whsec_three whsec_two])
  end

  it 'caps the overlap at 24 hours, as Stripe does' do
    expect { rotation.rotate(new_secret: 'whsec_two', now: clock.now, overlap: 86_401) }
      .to raise_error(described_class::InvalidRotation)
    expect { rotation.rotate(new_secret: 'whsec_two', now: clock.now, overlap: -1) }
      .to raise_error(described_class::InvalidRotation)
    expect(rotation.rotate(new_secret: 'whsec_two', now: clock.now, overlap: 86_400).previous).to eq('whsec_one')
  end

  it 'refuses a rotation to the same secret' do
    expect { rotation.rotate(new_secret: 'whsec_one', now: clock.now, overlap: 60) }
      .to raise_error(described_class::InvalidRotation)
  end

  it 'refuses inconsistent values' do
    expect { described_class.new(current: '') }.to raise_error(described_class::InvalidRotation)
    expect { described_class.new(current: 'a', previous: 'b') }.to raise_error(described_class::InvalidRotation)
    expect { described_class.new(current: 'a', previous_expires_at: clock.now) }
      .to raise_error(described_class::InvalidRotation)
    expect { described_class.new(current: 'a', previous: 'a', previous_expires_at: clock.now) }
      .to raise_error(described_class::InvalidRotation)
  end

  it 'prunes an expired previous secret and leaves a live one alone' do
    rotated = rotation.rotate(new_secret: 'whsec_two', now: clock.now, overlap: 60)
    expect(rotated.prune(now: clock.now)).to equal(rotated)
    pruned = rotated.prune(now: clock.now + 60)
    expect([pruned.current, pruned.previous, pruned.previous_expires_at]).to eq(['whsec_two', nil, nil])
    expect(rotation.prune(now: clock.now)).to equal(rotation)
  end

  it 'generates distinct whsec_ secrets with 256 bits of randomness' do
    a = described_class.generate_secret
    b = described_class.generate_secret
    expect(a).to start_with('whsec_')
    expect(a).not_to eq(b)
    expect(Base64.urlsafe_decode64(a.delete_prefix('whsec_')).bytesize).to eq(32)
  end

  it 'produces secrets the signer and verifier agree on through a whole rotation' do
    sig = Clearinghouse::Webhooks::Signature
    rotated = described_class.generate.then { |r| r.rotate(new_secret: 'whsec_new', now: clock.now, overlap: 600) }
    header = sig.sign(payload: '{}', secrets: rotated.active_secrets(now: clock.now), timestamp: clock.now.to_i)
    # A merchant that has not deployed the new secret yet still verifies.
    expect(sig.verify(payload: '{}', header: header, secrets: [T.must(rotated.previous)], now: clock.now.to_i))
      .to be_valid
    expect(sig.verify(payload: '{}', header: header, secrets: ['whsec_new'], now: clock.now.to_i)).to be_valid
  end
end
