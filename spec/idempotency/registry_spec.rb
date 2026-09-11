# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Idempotency::Registry do
  let(:idem) { Clearinghouse::Idempotency }
  let(:payments) { Clearinghouse::Payments::Flows.registry }

  def phase(from, to)
    idem::Phase.new(from: from, to: to, atomic: ->(_r, _d, _f) {})
  end

  def flow_with(phases, name: 'spec.broken')
    Class.new(idem::Flow) do
      define_method(:name) { name }
      define_method(:phases) { phases }
      define_method(:load_input) { |_h| raise 'unused' }
    end.new
  end

  it 'derives recovery points from the phases, confirm exactly as designed' do
    expect(payments.fetch('payment_intent.confirm').recovery_points)
      .to eq(%w[started intent_locked risk_assessed authorization_requested authorization_recorded ledger_posted
                finished])
    expect(payments.fetch('payment_intent.capture').recovery_points)
      .to eq(%w[started intent_locked capture_requested capture_recorded finished])
    expect(payments.fetch('payment_intent.cancel').recovery_points)
      .to eq(%w[started intent_locked void_requested canceled finished])
    expect(payments.fetch('refund.create').recovery_points)
      .to eq(%w[started refund_created refund_requested refund_recorded finished])
    expect(payments.fetch('payment_intent.create').recovery_points).to eq(%w[started finished])
  end

  it 'makes every foreign call from a phase that starts at a *_requested point, committed before the call' do
    payments.flows.each do |flow|
      flow.phases.select(&:foreign).each do |p|
        expect(p.from).to match(/_requested\z|\Aintent_locked\z/), "#{flow.name}: foreign call from #{p.from}"
      end
    end
  end

  it 'enumerates every recovery point of every flow, after and before commit' do
    points = payments.crash_points
    expected = payments.flows.sum { |f| f.recovery_points.length } * 2
    expect(points.length).to eq(expected)
    expect(points.map(&:to_s)).to include('payment_intent.confirm:authorization_requested',
                                          'payment_intent.confirm:authorization_requested:before_commit',
                                          'refund.create:finished')
  end

  it 'refuses a flow whose phases do not chain from started to finished' do
    expect { described_class.new([flow_with([phase('started', 'a'), phase('b', 'finished')])]) }
      .to raise_error(idem::Flow::DefinitionError, /got started -> a, b -> finished/)
    expect { described_class.new([flow_with([phase('started', 'a')])]) }.to raise_error(idem::Flow::DefinitionError)
    expect { described_class.new([flow_with([phase('started', 'started'), phase('started', 'finished')])]) }
      .to raise_error(idem::Flow::DefinitionError)
  end

  it 'refuses two flows with one name, and names an unknown one' do
    ok = flow_with([phase('started', 'finished')], name: 'spec.ok')
    registry = described_class.new([ok])
    expect { registry.register(ok) }.to raise_error(ArgumentError, /already registered/)
    expect { registry.fetch('spec.nope') }.to raise_error(described_class::UnknownFlowError)
    expect { ok.phase_from('middle') }.to raise_error(idem::Flow::DefinitionError, /no phase from middle/)
  end
end
