# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Risk::Assessment do
  let(:valid) do
    { 'assessment_id' => 'asm_1', 'decision' => 'review', 'risk_score' => 64, 'matched_rule' => 'velocity_1h',
      'reasons' => %w[a b c], 'ruleset_version' => '2026-09-01.3' }
  end

  it 'builds from a response that meets the contract' do
    expect(described_class.from_json(valid, replayed: true))
      .to have_attributes(assessment_id: 'asm_1', decision: 'review', risk_score: 64, matched_rule: 'velocity_1h',
                          reasons: %w[a b c], ruleset_version: '2026-09-01.3', replayed: true)
  end

  it 'accepts the edges: score 0 and 99, no matched rule, no reasons, a numeric rule-set version' do
    parsed = described_class.from_json(valid.merge('risk_score' => 0, 'matched_rule' => nil, 'reasons' => [],
                                                   'ruleset_version' => 12))
    expect(parsed).to have_attributes(risk_score: 0, matched_rule: nil, reasons: [], ruleset_version: '12')
    expect(described_class.from_json(valid.merge('risk_score' => 99)).risk_score).to eq(99)
  end

  {
    'a non-object body' => [nil, /not an object/],
    'a missing assessment_id' => [{ 'assessment_id' => nil }, /assessment_id/],
    'an empty assessment_id' => [{ 'assessment_id' => '' }, /assessment_id/],
    'an unknown decision' => [{ 'decision' => 'maybe' }, /decision "maybe"/],
    'a score of 100' => [{ 'risk_score' => 100 }, /risk_score 100/],
    'a negative score' => [{ 'risk_score' => -1 }, /risk_score -1/],
    'a fractional score' => [{ 'risk_score' => 50.5 }, /risk_score 50.5/],
    'a numeric matched_rule' => [{ 'matched_rule' => 3 }, /matched_rule/],
    'four reasons' => [{ 'reasons' => %w[a b c d] }, /at most 3/],
    'a non-string reason' => [{ 'reasons' => [1] }, /at most 3/],
    'a missing ruleset_version' => [{ 'ruleset_version' => nil }, /ruleset_version/]
  }.each do |name, (change, message)|
    it "refuses #{name}" do
      json = change.nil? ? [] : valid.merge(change)
      expect { described_class.from_json(json) }.to raise_error(described_class::Invalid, message)
    end
  end
end
