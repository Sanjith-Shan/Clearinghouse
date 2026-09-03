# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Versioning::Changelog do
  it 'matches the committed docs/api-changelog.md (run bin/changelog if not)' do
    expect(File.read(described_class::PATH)).to eq(described_class.render(Clearinghouse::Versioning.registry))
  end

  it 'lists versions newest first with each change under its date' do
    text = described_class.render(Clearinghouse::Versioning.registry)
    headings = text.scan(/^## (\S+)$/).flatten
    expect(headings).to eq(%w[2026-09-01 2026-06-01 2026-03-01 2026-01-01])
    expect(text[/## 2026-03-01\n\n(.*?)\n\n/m, 1]).to include('`amount_captured` is renamed to `amount_received`')
  end
end
