# typed: false
# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require_relative '../coverage_groups'

RSpec.describe CoverageGroups do
  describe '.product? and .harness?' do
    {
      'lib/clearinghouse/payments/service.rb' => :product,
      'lib/clearinghouse/ledger.rb' => :product,
      'lib/clearinghouse.rb' => :product,
      'sim/lib/acquirer_sim/app.rb' => :product,
      'sim/lib/acquirer_sim.rb' => :product,
      'clients/ruby/lib/clearinghouse_client/client.rb' => :product,
      'lib/clearinghouse/testing/crash_points.rb' => :harness,
      'lib/clearinghouse/experiments/replay.rb' => :harness,
      'sim/experiments/storm.rb' => :harness,
      'sim/fake_riskgate/lib/fake_riskgate.rb' => :harness
    }.each do |path, scope|
      it "puts #{path} in #{scope} code" do
        expect(described_class.product?(path)).to eq(scope == :product)
        expect(described_class.harness?(path)).to eq(scope == :harness)
      end
    end

    it 'claims harness files for the harness group before any product group' do
      expect(described_class.group_of('lib/clearinghouse/testing/crash_points.rb')).to eq('Harness and tools')
      expect(described_class.group_of('lib/clearinghouse/api/app.rb')).to eq('API')
    end
  end

  describe '.violations' do
    let(:ledger) { { 'lib/clearinghouse/ledger/posting.rb' => [1] * 20 } }

    it 'ignores harness coverage, however low' do
      hits = ledger.merge('sim/experiments/storm.rb' => [0] * 100)
      expect(described_class.violations(hits)).to eq([])
    end

    it 'fails product code below the product floor' do
      hits = ledger.merge('lib/clearinghouse/api/app.rb' => ([1] * 70) + ([0] * 30))
      expect(described_class.violations(hits))
        .to eq(["product code: branch coverage 75.00% is below #{described_class::PRODUCT_FLOOR}%"])
    end

    it 'still holds the ledger to 95% on its own' do
      hits = { 'lib/clearinghouse/ledger/posting.rb' => ([1] * 94) + ([0] * 6),
               'lib/clearinghouse/api/app.rb' => [1] * 1000 }
      expect(described_class.violations(hits)).to eq(['Ledger: branch coverage 94.00% is below 95.0%'])
    end
  end

  # The gate itself, in a child rspec as bin/ci runs it. No database needed.
  describe 'the gate in spec_helper' do
    it 'stays out of the way of a failing run, so the failures are what gets reported' do
      root = File.expand_path('../..', __dir__)
      Dir.mktmpdir do |dir|
        _, err, status = Open3.capture3({ 'COVERAGE_GATE' => '1', 'COVERAGE_DIR' => dir, 'NO_COVERAGE' => nil },
                                        'bundle', 'exec', 'rspec', 'spec/fixtures/coverage_gate/failing_example.rb',
                                        chdir: root)
        expect(status.exitstatus).to eq(1)
        expect(err).not_to include('Coverage gate failed')
      end
    end
  end
end
