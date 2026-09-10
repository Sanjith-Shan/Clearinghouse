# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Risk::Decision do
  def assessment(decision, score: 40)
    Clearinghouse::Risk::Assessment.new(assessment_id: 'asmt_1', decision: decision, risk_score: score,
                                        matched_rule: nil, reasons: ['r1'], ruleset_version: '3')
  end

  let(:action) { described_class::Action }

  it 'lets allow through with no hold' do
    verdict = described_class.apply(assessment('allow', score: 4))
    expect(verdict).to have_attributes(action: action::Proceed, hold: false, error: nil, checked?: true)
    expect(verdict.risk).to eq('decision' => 'allow', 'score' => 4, 'reasons' => ['r1'], 'assessment_id' => 'asmt_1',
                               'ruleset_version' => '3')
  end

  it 'lets review through and asks for a payout hold' do
    verdict = described_class.apply(assessment('review', score: 70))
    expect(verdict).to have_attributes(action: action::Proceed, hold: true, error: nil)
    expect(verdict.risk).to include('decision' => 'review', 'score' => 70)
  end

  it 'blocks with a risk_error / payment_blocked, a 402 that says not to retry' do
    verdict = described_class.apply(assessment('block', score: 98))
    expect(verdict).to have_attributes(action: action::Block, hold: false, proceed?: false)
    expect(verdict.error).to have_attributes(type: 'risk_error', code: 'payment_blocked', http_status: 402)
    expect(verdict.risk).to include('decision' => 'block', 'score' => 98)
  end

  Clearinghouse::Risk::UnavailableReason.values.map(&:serialize).each do |name|
    it "fails open on #{name}, recording risk_unavailable and why" do
      reason = Clearinghouse::Risk::UnavailableReason.deserialize(name)
      verdict = described_class.apply(Clearinghouse::Risk::Unavailable.new(reason: reason, detail: 'x'))
      expect(verdict).to have_attributes(action: action::Proceed, hold: false, error: nil, checked?: false)
      expect(verdict.risk).to eq('decision' => 'risk_unavailable', 'reason' => name)
    end
  end
end
