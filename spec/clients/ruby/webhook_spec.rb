# typed: false
# frozen_string_literal: true

require_relative 'client_helper'

RSpec.describe ClearinghouseClient::Webhook do
  let(:server_signature) { Clearinghouse::Webhooks::Signature }
  let(:secret) { 'whsec_test_client_secret' }
  let(:payload) { '{"id":"evt_1","object":"event","type":"payout.paid","data":{"object":{"id":"po_1"}}}' }

  describe 'the shared vectors in spec/fixtures/signatures.json' do
    SignatureVectors.all.each do |vector|
      it vector['name'] do
        verify = lambda do
          ClearinghouseClient::Webhook::Signature.verify_header(
            vector['payload'], vector['header'], vector['secrets'], tolerance: vector['tolerance'], now: vector['now']
          )
        end
        if vector['valid']
          expect(verify.call).to be_a(Integer)
        else
          expect(&verify).to raise_error(ClearinghouseClient::SignatureVerificationError) { |e|
            expect(e.code).to eq(vector['error'])
            expect(e.header).to eq(vector['header'])
          }
        end
      end
    end
  end

  # The vectors pin the rules down at chosen points. This checks the two copies agree
  # everywhere else a random header can reach: built from the pieces the grammar is
  # made of, so most headers are near-misses rather than garbage.
  it 'agrees with the server verifier on 3000 generated headers' do
    rng = Random.new(20_260_923)
    now = 1_700_000_000
    good = server_signature.compute(secret, now.to_s, payload)
    pieces = ['t=', 'v1=', 'v0=', ',', ' ', "\t", '=', 'T=', now.to_s, (now - 301).to_s, '0', '-1', good,
              good.upcase, good[0, 10], 'x', '']
    3000.times do
      header = Array.new(rng.rand(1..7)) { pieces.sample(random: rng) }.join
      server = server_signature.verify(payload: payload, header: header, secrets: [secret], now: now)
      client = begin
        described_class::Signature.verify_header(payload, header, [secret], tolerance: 300, now: now)
        nil
      rescue ClearinghouseClient::SignatureVerificationError => e
        e.code
      end
      expect(client).to eq(server.error&.serialize), "header #{header.inspect}"
    end
  end

  describe '.construct_event' do
    let(:header) { server_signature.sign(payload: payload, secrets: [secret], timestamp: 1_700_000_000) }

    it 'returns the parsed event when the signature verifies' do
      event = described_class.construct_event(payload, header, secret, now: 1_700_000_100)
      expect(event).to include('id' => 'evt_1', 'type' => 'payout.paid')
    end

    it 'accepts a list of secrets during a rotation' do
      event = described_class.construct_event(payload, header, ['whsec_old', secret], now: 1_700_000_000)
      expect(event['id']).to eq('evt_1')
    end

    it 'defaults to the wall clock' do
      fresh = server_signature.sign(payload: payload, secrets: [secret], timestamp: Time.now.to_i)
      expect(described_class.construct_event(payload, fresh, secret)['id']).to eq('evt_1')
      expect { described_class.construct_event(payload, header, secret) }
        .to raise_error(ClearinghouseClient::SignatureVerificationError, /timestamp_outside_tolerance/)
    end

    it 'honours a custom tolerance' do
      expect { described_class.construct_event(payload, header, secret, tolerance: 10, now: 1_700_000_011) }
        .to raise_error(ClearinghouseClient::SignatureVerificationError) { |e|
          expect(e.code).to eq('timestamp_outside_tolerance')
        }
    end

    it 'rejects a body re-serialised after signing' do
      reformatted = JSON.pretty_generate(JSON.parse(payload))
      expect { described_class.construct_event(reformatted, header, secret, now: 1_700_000_000) }
        .to raise_error(ClearinghouseClient::SignatureVerificationError, /no_matching_signature/)
    end

    it 'raises InvalidPayloadError for a signed body that is not a JSON object' do
      %w[not-json [1] ""].each do |body|
        signed = server_signature.sign(payload: body, secrets: [secret], timestamp: 1_700_000_000)
        expect { described_class.construct_event(body, signed, secret, now: 1_700_000_000) }
          .to raise_error(ClearinghouseClient::InvalidPayloadError)
      end
    end

    it 'refuses to verify with no secret or a negative tolerance' do
      expect { described_class.construct_event(payload, header, [], now: 1) }.to raise_error(ArgumentError)
      expect { described_class.construct_event(payload, header, '', now: 1) }.to raise_error(ArgumentError)
      expect { described_class.construct_event(payload, header, secret, tolerance: -1, now: 1) }
        .to raise_error(ArgumentError)
    end
  end
end
