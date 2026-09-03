# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Versioning::Registry do
  it 'orders changes newest first for walking back' do
    a = build_change(version: '2026-02-01')
    b = build_change(version: '2026-05-01')
    registry = described_class.new(initial: '2026-01-01', changes: [a, b])
    expect(registry.changes_after('2026-01-01')).to eq([b, a])
    expect(registry.changes_after('2026-02-01')).to eq([b])
    expect(registry.changes_after('2026-05-01')).to eq([])
  end

  it 'lets several changes share a version' do
    registry = described_class.new(initial: '2026-01-01', changes: [build_change(version: '2026-02-01'),
                                                                    build_change(version: '2026-02-01')])
    expect(registry.versions).to eq(%w[2026-01-01 2026-02-01])
    expect(registry.changes_after('2026-01-01').size).to eq(2)
  end

  it 'rejects a version that is not a real date' do
    expect { described_class.new(initial: '2026-01-01', changes: [build_change(version: '2026-02-30')]) }
      .to raise_error(described_class::InvalidRegistryError)
    expect { described_class.new(initial: '26-1-1', changes: []) }.to raise_error(described_class::InvalidRegistryError)
  end

  it 'rejects a change dated on or before the initial version' do
    expect { described_class.new(initial: '2026-01-01', changes: [build_change(version: '2026-01-01')]) }
      .to raise_error(described_class::InvalidRegistryError)
  end

  it 'rejects a change that declares no resources' do
    expect { described_class.new(initial: '2026-01-01', changes: [build_change(version: '2026-02-01', resources: [])]) }
      .to raise_error(described_class::InvalidRegistryError)
  end

  it 'finds a registered change by class and refuses an unregistered one' do
    registry = Clearinghouse::Versioning.registry
    klass = Clearinghouse::Versioning::Changes::AmountReceivedRename
    expect(registry.find(klass)).to be_a(klass)
    expect { described_class.new(initial: '2026-01-01', changes: []).find(klass) }.to raise_error(ArgumentError)
  end

  it 'gives every shipped change a description for the changelog' do
    Clearinghouse::Versioning.registry.changes.each { |c| expect(c.description.length).to be > 20 }
  end
end
