# typed: false
# frozen_string_literal: true

require 'tmpdir'
require_relative '../../sim/experiments/crash_matrix'

# The matrix is the registry: every crash point, nothing hand-listed, and a flow
# that nobody wrote a scenario for stops the run instead of being skipped.
RSpec.describe 'Experiment 2 crash matrix plan' do
  let(:cm) { Experiments::CrashMatrix }
  let(:registry) { Clearinghouse::Payments::Flows.registry }
  let(:background) { Clearinghouse::Settlement.background_crash_points }

  def phase(from, to)
    Clearinghouse::Idempotency::Phase.new(from: from, to: to, atomic: ->(_run, _db, _foreign) {})
  end

  def flow_named(name, *points)
    chain = ['started', *points, 'finished']
    phases = chain.each_cons(2).map { |a, b| phase(a, b) }
    Class.new(Clearinghouse::Idempotency::Flow) do
      define_method(:name) { name }
      define_method(:phases) { phases }
      define_method(:load_input) { |_hash| raise NotImplementedError }
    end.new
  end

  it 'covers registry.crash_points, then the background crash points, exactly and in order, before any variant' do
    plan = cm.plan(registry)
    requests, jobs = plan.reject(&:variant).partition { |c| !c.background }
    expect(requests.map(&:crash_name)).to eq(registry.crash_points.map(&:to_s))
    expect(jobs.map(&:crash_name)).to eq(background.map(&:to_s))
    expect(plan.reject(&:variant)).to eq(requests + jobs)
    expect(plan.reject(&:variant).map(&:crash_name).uniq.length)
      .to eq(registry.crash_points.length + background.length)
    expect(plan.select(&:variant).map(&:name)).to eq(['payment_intent.confirm:authorization_requested+acquirer_drop'])
  end

  it 'has a scenario for every registered flow' do
    expect(registry.flows.map(&:name)).to all(satisfy { |name| cm.scenario_for(name).flow == name })
  end

  it "enumerates bin/poller's recovery points for every notification type a handler is registered for" do
    types = Clearinghouse::Settlement.notification_handlers(clock: Clearinghouse::Clock::Test.new).types
    expect(types).to eq(%w[dispute.closed dispute.opened payout.failed payout.paid])
    expect(background.map(&:to_s)).to eq(types.flat_map do |type|
      Clearinghouse::Acquirer::NotificationPoller::RECOVERY_POINTS.map { |point| "notification.#{type}:#{point}" }
    end)
  end

  it 'has a scenario for every background flow' do
    expect(background.map(&:flow).uniq).to all(satisfy { |name| cm.background_scenario_for(name).flow == name })
    expect(cm.flows_without_scenario(registry)).to eq([])
  end

  it 'plans a notification type with no scenario, and its cases fail instead of vanishing' do
    extra = Clearinghouse::Acquirer::NotificationPoller::RECOVERY_POINTS.map do |point|
      Clearinghouse::Idempotency::Registry::CrashPoint.new(flow: 'notification.spec.unhandled', point: point,
                                                           moment: :after_commit)
    end
    plan = cm.plan(registry, variants: false, background: background + extra)
    expect(plan.last(3).map(&:crash_name)).to eq(%w[notification_fetched effects_written committed].map do |p|
      "notification.spec.unhandled:#{p}"
    end)
    expect(plan.last(3)).to all(have_attributes(background: true))
    expect(cm.flows_without_scenario(registry, background: background + extra)).to eq(['notification.spec.unhandled'])

    proxy = cm::RecordingProxy.new(upstream_port: 1)
    runner = cm::BackgroundRunner.new(settings: cm::Settings.new(db_name: 'unused', log_dir: Dir.tmpdir),
                                      sim_url: 'http://127.0.0.1:1', proxy: proxy, riskgate_url: 'http://127.0.0.1:1',
                                      db: Sequel.mock, owner_db: Sequel.mock)
    result = runner.run(plan.last, 1)
    proxy.stop
    expect([result.passed?, result.error])
      .to match([false, /MissingScenarioError: background flow notification\.spec\.unhandled/])
  end

  it 'plans a flow with no scenario like any other, and its cases fail instead of vanishing' do
    extended = Clearinghouse::Idempotency::Registry.new([*registry.flows, flow_named('spec.unscenarioed', 'paid')])
    plan = cm.plan(extended, variants: false, background: [])
    expect(plan.map(&:crash_name)).to eq(extended.crash_points.map(&:to_s))
    expect(plan.last(6).map(&:crash_name)).to all(start_with('spec.unscenarioed:'))
    expect(cm.flows_without_scenario(extended)).to eq(['spec.unscenarioed'])

    proxy = cm::RecordingProxy.new(upstream_port: 1)
    runner = cm::CaseRunner.new(settings: cm::Settings.new(db_name: 'unused', log_dir: Dir.tmpdir),
                                sim_url: 'http://127.0.0.1:1', proxy: proxy, riskgate_url: 'http://127.0.0.1:1',
                                db: Sequel.mock, owner_db: Sequel.mock)
    result = runner.run(plan.last, 1)
    proxy.stop
    expect([result.passed?, result.error]).to match([false, /MissingScenarioError: flow spec\.unscenarioed/])
    expect(cm.headline([result], full: true)).to eq('crashed at 1 point across 1 flow, recovered at 0 of 1')
  end

  it 'picks up a new recovery point with no change to the harness' do
    toy = Clearinghouse::Idempotency::Registry.new([flow_named('toy.flow', 'a', 'b')])
    plan = cm.plan(toy, variants: false, background: [])
    expect(plan.map(&:crash_name)).to eq(%w[started a b finished].flat_map do |p|
      ["toy.flow:#{p}", "toy.flow:#{p}:before_commit"]
    end)

    grown = Clearinghouse::Idempotency::Registry.new([flow_named('toy.flow', 'a', 'a2', 'b')])
    names = cm.plan(grown, variants: false, background: []).map(&:crash_name)
    expect(names).to include('toy.flow:a2', 'toy.flow:a2:before_commit')
  end

  it 'knows where the key row must be after each kind of crash' do
    plan = cm.plan(registry).reject(&:variant).to_h { |c| [c.crash_name, c] }
    expect(plan.fetch('payment_intent.confirm:authorization_recorded').expected_point_after_crash)
      .to eq('authorization_recorded')
    expect(plan.fetch('payment_intent.confirm:authorization_recorded:before_commit').expected_point_after_crash)
      .to eq('authorization_requested')
    expect(plan.fetch('refund.create:started:before_commit').expected_point_after_crash).to be_nil
  end

  it 'narrows by name for development' do
    names = cm.plan(registry, only: ['refund.create:refund_recorded']).map(&:name)
    expect(names).to eq(%w[refund.create:refund_recorded refund.create:refund_recorded:before_commit])
  end

  it 'uses names the crash hook accepts' do
    fired = []
    registry.crash_points.each do |cp|
      hook = Clearinghouse::Idempotency::CrashHook::Armed.new(
        cm.plan(registry).find { |c| c.flow == cp.flow && c.point == cp.point && c.moment == cp.moment }.crash_name,
        env: { 'CLEARINGHOUSE_ENV' => 'test' }, action: -> { fired << cp.to_s }
      )
      hook.reached(cp.flow, cp.point, cp.moment)
    end
    expect(fired).to eq(registry.crash_points.map(&:to_s))
  end

  it "uses background names bin/poller's hook fires on, for that notification type only" do
    fired = []
    cm.plan(registry, variants: false).select(&:background).each do |kase|
      armed = Clearinghouse::Idempotency::CrashHook::Armed.new(kase.crash_name, env: { 'CLEARINGHOUSE_ENV' => 'test' },
                                                                                action: -> { fired << kase.name })
      hook = Clearinghouse::Acquirer::NotificationPoller.crash_hook(armed)
      type = kase.flow.delete_prefix('notification.')
      hook.call(kase.point, type == 'dispute.opened' ? 'payout.paid' : 'dispute.opened') # another type: no crash
      hook.call(kase.point, type)
    end
    expect(fired).to eq(background.map(&:to_s))
  end

  describe 'normalisation' do
    let(:normalize) { cm::Normalize }

    it 'rewrites only ids and created, keeping which id is which' do
      a = { 'id' => "pi_#{'a' * 24}", 'latest_charge' => "ch_#{'b' * 24}", 'created' => 1,
            'risk' => { 'assessment_id' => 'asm_00000001' }, 'status' => 'succeeded', 'amount' => 2000 }
      b = a.merge('id' => "pi_#{'c' * 24}", 'latest_charge' => "ch_#{'d' * 24}", 'created' => 2,
                  'risk' => { 'assessment_id' => 'asm_00000002' })
      expect(normalize.call(a)).to eq(normalize.call(b))
      expect(normalize.call(a)).to include('id' => '<pi#1>', 'created' => '<created>', 'status' => 'succeeded')
      expect(normalize.call(a)).not_to eq(normalize.call(b.merge('amount' => 1999)))
      expect(normalize.call(a)).not_to eq(normalize.call(b.merge('status' => 'processing')))
    end

    it 'notices a reference that points at the wrong object' do
      one = { 'id' => "pi_#{'a' * 24}", 'events' => ["pi_#{'a' * 24}"] }
      other = { 'id' => "pi_#{'a' * 24}", 'events' => ["pi_#{'z' * 24}"] }
      expect(normalize.call(one)).not_to eq(normalize.call(other))
    end

    it 'leaves test tokens and state names alone' do
      expect(normalize.call('pm_card_visa requires_confirmation')).to eq('pm_card_visa requires_confirmation')
    end
  end

  describe 'the before_commit comparison' do
    def result(name, snapshot, baseline: nil)
      kase = cm.plan(registry).find { |c| c.name == name }
      cm::CaseResult.new(kase: kase, crash_snapshot: snapshot, baseline_snapshot: baseline)
    end

    it 'passes when a rolled-back phase leaves what the previous commit left, and fails otherwise' do
      after = result('refund.create:refund_created', { 'refunds' => [] })
      good = result('refund.create:refund_requested:before_commit', { 'refunds' => [] })
      bad = result('refund.create:refund_recorded:before_commit', { 'refunds' => ['pending'] })
      prev = result('refund.create:refund_requested', { 'refunds' => [] })
      first = result('refund.create:started:before_commit', { 'k' => nil }, baseline: { 'k' => nil })
      cm.compare_rollbacks([after, good, bad, prev, first])
      expect([good, bad, first].map { |r| r.checks.map(&:ok) }).to eq([[true], [false], [true]])
      expect(after.checks).to be_empty
    end
  end

  it 'computes the headline from what ran and claims nothing for a partial run' do
    kases = cm.plan(registry, variants: false).first(3)
    results = kases.map { |k| cm::CaseResult.new(kase: k) }
    results.last.checks << cm::Check.new(name: 'crashed', ok: false)
    expect(cm.headline(results, full: true)).to eq('crashed at 3 points across 1 flow, recovered at 2 of 3')
    expect(cm.headline(results.first(2), full: false)).to start_with('PARTIAL RUN')

    everything = cm.plan(registry, variants: false).map { |k| cm::CaseResult.new(kase: k) }
    flows = registry.flows.length + background.map(&:flow).uniq.length
    expect(cm.headline(everything, full: true))
      .to eq("crashed at #{everything.length} points across #{flows} flows, recovered at all #{everything.length}")
  end
end
