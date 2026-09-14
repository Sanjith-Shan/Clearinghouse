# typed: false
# frozen_string_literal: true

require_relative '../../exp/webhooks/analysis'

RSpec.describe Experiments::Webhooks::Analysis, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:dir) { Dir.mktmpdir }
  let(:log_path) { File.join(dir, 'server.jsonl') }
  let(:merchant) { Clearinghouse::Merchants.create(app_db, clock: clock, name: 'M', api_version: '2026-09-01').first }
  let(:endpoints) do
    %w[healthy healthy hang].each_with_index.to_h do |kind, number|
      hook = WebhookSpecHelpers.create_endpoint(app_db, clock: clock, merchant_id: merchant.id,
                                                        url: "https://hooks.example.com/#{number}")
      [number, [hook.id, merchant.id, kind]]
    end
  end

  after { FileUtils.remove_entry(dir) }

  def log(*lines)
    File.write(log_path, lines.map { |line| "#{JSON.generate(line)}\n" }.join)
  end

  it 'measures time to the first 200 per healthy pair, and counts duplicates and missing pairs' do
    endpoints
    first = WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id)
    second = WebhookSpecHelpers.emit(app_db, clock: clock, merchant_id: merchant.id)
    t0 = clock.now.to_f
    log({ 't' => t0 + 0.5, 'ep' => 0, 'kind' => 'healthy', 'evt' => first, 'status' => 500, 'sig' => true },
        { 't' => t0 + 2.0, 'ep' => 0, 'kind' => 'healthy', 'evt' => first, 'status' => 200, 'sig' => true },
        { 't' => t0 + 3.0, 'ep' => 0, 'kind' => 'healthy', 'evt' => first, 'status' => 200, 'sig' => true },
        { 't' => t0 + 1.0, 'ep' => 1, 'kind' => 'healthy', 'evt' => first, 'status' => 200, 'sig' => true },
        { 't' => t0 + 4.0, 'ep' => 0, 'kind' => 'healthy', 'evt' => second, 'status' => 200, 'sig' => false },
        { 't' => t0 + 0.1, 'ep' => 2, 'kind' => 'hang', 'evt' => first, 'status' => nil, 'sig' => true })

    summary = described_class.new(db: app_db, topology: endpoints, log_path: log_path).summary
    expect(summary).to include('events' => 2, 'healthy_pairs_expected' => 4, 'healthy_pairs_received' => 3,
                               'missing' => 1, 'healthy_receipts' => 4, 'duplicates' => 1,
                               'signature_failures' => 1, 'requests_by_kind' => { 'hang' => 1, 'healthy' => 5 })
    expect(summary['duplicate_rate']).to eq((1.0 / 3).round(6))
    expect(summary['ttd_s']).to eq('p50' => 2.0, 'p90' => 4.0, 'p99' => 4.0, 'max' => 4.0, 'mean' => 2.333)
  end

  it 'uses nearest-rank percentiles' do
    values = (1..100).map(&:to_f)
    expect(described_class.distribution(values)).to include('p50' => 50.0, 'p90' => 90.0, 'p99' => 99.0,
                                                            'max' => 100.0, 'mean' => 50.5)
    expect(described_class.distribution([])).to include('p50' => nil, 'max' => nil, 'mean' => nil)
  end
end
