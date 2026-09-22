# typed: false
# frozen_string_literal: true

require 'open3'

RSpec.describe Clearinghouse::Webhooks::Signature do
  let(:secret) { 'whsec_test_clearinghouse_single_secret' }
  let(:payload) { '{"id":"evt_1"}' }
  let(:now) { 1_700_000_000 }

  describe 'the shared vectors in spec/fixtures/signatures.json' do
    let(:vectors) { SignatureVectors.all }

    it 'covers every error code and both outcomes' do
      expect(vectors.map { |v| v['error'] }.uniq).to contain_exactly(
        nil, 'no_matching_signature', 'timestamp_outside_tolerance', 'malformed_header'
      )
      expect(vectors.map { |v| v['name'] }.uniq.length).to eq(vectors.length)
    end

    it 'keeps exactly the shape agreed with RiskGate' do
      vectors.each do |v|
        expect(v.keys).to eq(%w[name secrets payload header now tolerance valid error])
        expect(v['valid']).to eq(v['error'].nil?)
      end
    end

    it 'is what bin/gen-signature-vectors generates' do
      script = File.expand_path('../../../bin/gen-signature-vectors', __dir__)
      output, status = Open3.capture2e(script, '--check')
      expect(status).to be_success, output
    end
  end

  describe '.sign' do
    it 'matches an HMAC computed independently with openssl' do
      # printf '%s' '1700000000.{"id":"evt_1"}' | openssl dgst -sha256 -hmac whsec_test_clearinghouse_single_secret
      expect(described_class.sign(payload: payload, secrets: [secret], timestamp: now))
        .to eq('t=1700000000,v1=6f725583e4a1287c7f5fdce17433d48868a1e2a4e0fb3dea71c732e49bdf2c70')
    end

    it 'emits one v1 per secret, in the order given' do
      header = described_class.sign(payload: payload, secrets: %w[whsec_new whsec_old], timestamp: now)
      t, first, second = header.split(',')
      expect(t).to eq("t=#{now}")
      expect(first).to eq("v1=#{described_class.compute('whsec_new', now.to_s, payload)}")
      expect(second).to eq("v1=#{described_class.compute('whsec_old', now.to_s, payload)}")
    end

    it 'signs the raw bytes, whatever the string encoding says' do
      utf8 = '{"name":"café"}'
      expect(described_class.sign(payload: utf8, secrets: [secret], timestamp: now))
        .to eq(described_class.sign(payload: utf8.b, secrets: [secret], timestamp: now))
      # UTF-16 is not ASCII-compatible, so it only works if the payload is taken as bytes.
      utf16 = payload.encode('UTF-16LE')
      expect(described_class.sign(payload: utf16, secrets: [secret], timestamp: now))
        .to eq(described_class.sign(payload: utf16.b, secrets: [secret], timestamp: now))
    end

    it 'refuses no secrets, empty secrets and negative timestamps' do
      expect { described_class.sign(payload: payload, secrets: [], timestamp: now) }
        .to raise_error(ArgumentError, 'at least one secret is required')
      expect { described_class.sign(payload: payload, secrets: [''], timestamp: now) }
        .to raise_error(ArgumentError, 'secrets must not be empty strings')
      expect { described_class.sign(payload: payload, secrets: [secret, ''], timestamp: now) }
        .to raise_error(ArgumentError, 'secrets must not be empty strings')
      expect { described_class.sign(payload: payload, secrets: [secret], timestamp: -1) }
        .to raise_error(ArgumentError, 'timestamp must be non-negative, got -1')
    end
  end

  describe '.verify' do
    let(:header) { described_class.sign(payload: payload, secrets: [secret], timestamp: now) }

    # Nested under .verify so mutation testing counts the vectors as tests of verify.
    describe 'against the shared vectors' do
      SignatureVectors.all.each do |v|
        it "#{v['name']}: #{v['error'] || 'valid'}" do
          result = described_class.verify(payload: v['payload'], header: v['header'], secrets: v['secrets'],
                                          now: v['now'], tolerance: v['tolerance'])
          expect(result.valid?).to eq(v['valid'])
          expect(result.error&.serialize).to eq(v['error'])
        end
      end
    end

    describe 'against RiskGate’s vectors' do
      SignatureVectors.riskgate.each do |v|
        it "#{v['name']}: #{v['error'] || 'valid'}" do
          result = described_class.verify(payload: v['payload'], header: v['header'], secrets: v['secrets'],
                                          now: v['now'], tolerance: v['tolerance'])
          expect(result.valid?).to eq(v['valid'])
          expect(result.error&.serialize).to eq(v['error'])
        end
      end
    end

    it 'returns the timestamp it verified' do
      result = described_class.verify(payload: payload, header: header, secrets: [secret], now: now)
      expect(result.timestamp).to eq(now)
    end

    it 'reports the timestamp on failures too, so a caller can log the skew' do
      stale = described_class.verify(payload: payload, header: header, secrets: [secret], now: now + 301)
      forged = described_class.verify(payload: payload, header: header, secrets: ['whsec_other'], now: now)
      malformed = described_class.verify(payload: payload, header: 'nope', secrets: [secret], now: now)
      expect([stale.timestamp, forged.timestamp, malformed.timestamp]).to eq([now, now, nil])
    end

    it 'defaults to Stripe’s five-minute tolerance' do
      expect(described_class.verify(payload: payload, header: header, secrets: [secret], now: now + 300)).to be_valid
      expect(described_class.verify(payload: payload, header: header, secrets: [secret], now: now + 301))
        .not_to be_valid
    end

    it 'treats a zero tolerance as "exactly now", never as "skip the check"' do
      expect(described_class.verify(payload: payload, header: header, secrets: [secret], now: now, tolerance: 0))
        .to be_valid
      result = described_class.verify(payload: payload, header: header, secrets: [secret], now: now + 1, tolerance: 0)
      expect(result.error).to eq(described_class::ErrorCode::TimestampOutsideTolerance)
    end

    it 'refuses a negative tolerance and an empty secret list' do
      expect { described_class.verify(payload: payload, header: header, secrets: [secret], now: now, tolerance: -1) }
        .to raise_error(ArgumentError, 'tolerance must be non-negative, got -1')
      expect { described_class.verify(payload: payload, header: header, secrets: [], now: now) }
        .to raise_error(ArgumentError)
    end

    it 'finds the valid signature after any number of elements in schemes it does not know' do
      unknown = Array.new(200) { |i| "v0=#{format('%064x', i)}" }
      long = ([header] + unknown).join(',').sub(/,(v1=\h+)/, '') + ",#{header[/v1=\h+/]}"
      expect(long.count(',')).to eq(201)
      expect(described_class.verify(payload: payload, header: long, secrets: [secret], now: now)).to be_valid
    end

    it 'does not choke on a header that is not valid UTF-8' do
      result = described_class.verify(payload: payload, header: "t=#{now},v1=\xff\xfe", secrets: [secret], now: now)
      expect(result.error).to eq(described_class::ErrorCode::NoMatchingSignature)
    end

    it 'compares with OpenSSL.fixed_length_secure_compare, never ==' do
      allow(OpenSSL).to receive(:fixed_length_secure_compare).and_call_original
      described_class.verify(payload: payload, header: header, secrets: [secret], now: now)
      expect(OpenSSL).to have_received(:fixed_length_secure_compare).at_least(:once)
    end

    it 'round-trips any payload, secrets and timestamp within tolerance' do
      g = PropCheck::Generators
      secret_gen = g.printable_ascii_string.where { |s| !s.empty? }
      PropCheck.forall(body: g.string, secrets: g.array(secret_gen, min: 1, max: 3),
                       skew: g.choose(-300..300)) do |body:, secrets:, skew:|
        signed = described_class.sign(payload: body, secrets: secrets, timestamp: now)
        secrets.each do |one|
          expect(described_class.verify(payload: body, header: signed, secrets: [one], now: now + skew)).to be_valid
        end
      end
    end
  end

  describe '.verify!' do
    it 'returns the timestamp when valid' do
      header = described_class.sign(payload: payload, secrets: [secret], timestamp: now)
      expect(described_class.verify!(payload: payload, header: header, secrets: [secret], now: now)).to eq(now)
    end

    it 'passes the tolerance through' do
      header = described_class.sign(payload: payload, secrets: [secret], timestamp: now)
      expect(described_class.verify!(payload: payload, header: header, secrets: [secret], now: now + 600,
                                     tolerance: 600))
        .to eq(now)
    end

    it 'raises with the error code when not' do
      expect { described_class.verify!(payload: payload, header: 'nope', secrets: [secret], now: now) }
        .to raise_error(described_class::VerificationError, 'malformed_header') { |e|
          expect(e.code).to eq(described_class::ErrorCode::MalformedHeader)
        }
    end
  end
end
