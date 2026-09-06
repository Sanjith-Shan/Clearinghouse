# typed: false
# frozen_string_literal: true

require_relative 'client_helper'

RSpec.describe ClearinghouseClient::RetryPolicy do
  def response(status, headers = {})
    ClearinghouseClient::Response.new(status: status, headers: headers, body: '{}')
  end

  def policy(rand: 0.5, max_retries: 2)
    described_class.new(max_retries: max_retries, rng: FixedRandom.new(rand))
  end

  let(:dropped) { ClearinghouseClient::APIConnectionError.new('dropped', maybe_processed: true) }

  describe '#retry?' do
    it 'retries connection failures, whether or not the request was sent' do
      refused = ClearinghouseClient::APIConnectionError.new('refused', maybe_processed: false)
      expect(policy.retry?(0, connection_error: dropped)).to be(true)
      expect(policy.retry?(0, connection_error: refused)).to be(true)
    end

    it 'retries 409, 429 and every 5xx, and no other status' do
      retried = (400..599).select { |status| policy.retry?(0, response: response(status)) }
      expect(retried).to eq([409, 429, *500..599])
    end

    it "lets the server's Should-Retry header override the status in both directions" do
      expect(policy.retry?(0, response: response(500, 'clearinghouse-should-retry' => 'false'))).to be(false)
      expect(policy.retry?(0, response: response(400, 'clearinghouse-should-retry' => 'true'))).to be(true)
      expect(policy.retry?(0, response: response(500, 'clearinghouse-should-retry' => 'maybe'))).to be(true)
    end

    it 'stops once the retry budget is spent, whatever the error' do
      expect(policy(max_retries: 2).retry?(2, connection_error: dropped)).to be(false)
      expect(policy(max_retries: 2).retry?(1, response: response(503))).to be(true)
      expect(policy(max_retries: 0).retry?(0, response: response(503))).to be(false)
    end

    it 'gives up rather than retrying early when Retry-After asks for more than a minute' do
      expect(policy.retry?(0, response: response(429, 'retry-after' => '60'))).to be(true)
      expect(policy.retry?(0, response: response(429, 'retry-after' => '61'))).to be(false)
    end

    it 'rejects a negative budget' do
      expect { policy(max_retries: -1) }.to raise_error(ArgumentError, /max_retries/)
    end
  end

  describe '#delay' do
    it 'doubles the window each retry and caps it at 8 seconds' do
      top = policy(rand: 1.0)
      expect((1..7).map { |n| top.delay(n) }).to eq([0.5, 1.0, 2.0, 4.0, 8.0, 8.0, 8.0])
    end

    it 'draws uniformly from the whole window (full jitter)' do
      expect(policy(rand: 0.0).delay(3)).to eq(0.0)
      expect(policy(rand: 0.25).delay(3)).to eq(0.5)
    end

    it 'never waits less than Retry-After' do
      expect(policy(rand: 0.5).delay(1, retry_after: 3)).to eq(3.0)
      expect(policy(rand: 1.0).delay(5, retry_after: 3)).to eq(8.0)
    end

    it 'spreads a crowd of clients across the window with a real RNG' do
      real = described_class.new(max_retries: 2, rng: Random.new(42))
      delays = Array.new(1000) { real.delay(4) }
      expect(delays).to all(be >= 0.0).and all(be < 4.0)
      expect(delays.count { |d| d < 2.0 }).to be_between(400, 600)
    end

    it 'counts retries from 1' do
      expect { policy.delay(0) }.to raise_error(ArgumentError)
    end
  end
end
