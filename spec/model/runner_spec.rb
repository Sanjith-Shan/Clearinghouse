# typed: false
# frozen_string_literal: true

require 'stringio'
require_relative 'model_helper'

# A copy of the model with a bug planted in its bookkeeping: a refund also hands
# back the merchant's fee. Used to prove the harness notices, shrinks and
# reproduces a money bug, without a database.
class FeeReturningModel < Clearinghouse::Testing::Model::ReferenceModel
  private

  def entries(flow_id, kind, amount, merchant, fee)
    lines = super
    return lines unless kind == :refund

    lines + [['platform:fee_revenue', :debit, 1], ["merchant:#{merchant}:available", :credit, 1]]
  end
end

RSpec.describe Clearinghouse::Testing::Model::Runner, :model do
  def runner(factory, seed: 7, sequences: 20, max_length: 40)
    described_class.new(sut_factory: factory, sut_name: 'model', seed: seed, sequences: sequences,
                        max_length: max_length)
  end

  it 'runs the model against itself with every check passing' do
    report = runner(-> { ModelTesting::ReferenceModel.new }, sequences: 30).run
    expect(report.failure).to be_nil
    expect(report.stats.sequences).to eq(30)
    expect(report.stats.operations).to be > 30 * 20
  end

  it 'reaches the illegal paths, not only the happy ones' do
    outcomes = runner(-> { ModelTesting::ReferenceModel.new }, sequences: 30).run.stats.by_outcome.keys
    expect(outcomes).to include('confirm card_declined', 'capture parameter_invalid', 'refund parameter_invalid',
                                'refund charge_already_refunded', 'payout balance_insufficient',
                                'confirm payment_intent_unexpected_state', 'confirm resource_missing',
                                'create_intent amount_too_small')
  end

  it 'finds a planted bug, shrinks it to the three steps that matter, and renders a runnable script' do
    report = runner(-> { FeeReturningModel.new }).run
    found = report.failure
    expect(found).not_to be_nil
    expect(found.original_failure.violation.check).to eq(:balances)
    expect(found.shrunk.map(&:op)).to eq(%i[create_merchant create_intent refund].insert(2, :confirm))
    expect(found.shrunk.length).to be < found.original.length
    expect(found.shrunk_failure.violation.details).to include(a_string_matching(/platform:fee_revenue.*off by -1/))
    expect(found.script).to include('Harness.replay(sut: :model', 'h.refund(')
    expect { RubyVM::InstructionSequence.compile(found.script) }.not_to raise_error
  end

  it 'replays a script body on a harness and stops at the failing step' do
    found = runner(-> { FeeReturningModel.new }).run.failure
    out = StringIO.new
    harness = ModelTesting::Harness.new(FeeReturningModel.new, out: out)
    body = found.script[/do \|h\|\n(.*)\nend/m, 1]
    expect { harness.instance_eval(body.gsub(/^\s*h\./, '')) }
      .to raise_error(ModelTesting::Harness::Failed, /check balances failed/)
    expect(out.string).to include('model:  ok amount=')
  end

  it 'is deterministic for a seed' do
    first = runner(-> { FeeReturningModel.new }).run.failure
    second = runner(-> { FeeReturningModel.new }).run.failure
    expect(second.original.map(&:to_ruby)).to eq(first.original.map(&:to_ruby))
    expect(second.shrunk.map(&:to_ruby)).to eq(first.shrunk.map(&:to_ruby))
  end
end
