# typed: false
# frozen_string_literal: true

require_relative 'sim_helper'

RSpec.describe AcquirerSim::Simulator do
  let(:t0) { Time.utc(2026, 3, 1, 9, 0, 0) }
  let(:day) { 86_400 }

  # A month of mixed traffic in three currencies: captures, partial captures, refunds,
  # voids, declines, disputes won and lost.
  def month_of_traffic(sim)
    60.times do |i|
      at = t0 + (i * 11 * 3_600)
      pm = %w[pm_card_visa pm_card_disputeFraudulent pm_card_chargeDeclined pm_card_mastercard][i % 4]
      ref = sim.submit('authorize', "auth-#{i}", { 'payment_method' => pm, 'amount' => 1_000 + (i * 137),
                                                   'currency' => %w[usd jpy kwd][i % 3], 'capture' => i.even?,
                                                   'reference' => "pi_#{i}" }, at).operation.acquirer_reference
      sim.submit('capture', "cap-#{i}", { 'acquirer_reference' => ref, 'amount' => 900 }, at + 60) if i.odd?
      sim.submit('refund', "ref-#{i}", { 'acquirer_reference' => ref, 'amount' => 250 }, at + day) if (i % 5).zero?
      sim.submit('void', "void-#{i}", { 'acquirer_reference' => ref }, at + 120) if i % 7 == 3
    end
    sim.disputes.each_with_index do |d, i|
      sim.resolve_dispute(d.id, i.even? ? 'won' : 'lost', d.opened_at + (3 * day))
    end
  end

  # Every file's bytes and manifest for March.
  def run_month(seed:, inject: ->(_date) { [{ 'random' => 2 }] })
    sim = described_class.new
    sim.configure('seed' => seed)
    month_of_traffic(sim)
    (1..31).map do |d|
      date = Date.new(2026, 3, d)
      file = sim.settlement_file(date, inject.call(date), Time.utc(2026, 3, d, 23))
      [file.csv, file.manifest]
    end
  end

  it 'produces byte-identical files and manifests for the same seed and request sequence' do
    first = run_month(seed: 5)
    second = run_month(seed: 5)
    expect(second).to eq(first)
    expect(first.sum { |csv, _| csv.lines.size - 1 }).to be > 80
    expect(first.sum { |_, manifest| manifest['discrepancies'].size }).to eq(62)
  end

  it 'draws different random discrepancies for a different seed, over the same money' do
    a = run_month(seed: 5)
    b = run_month(seed: 6)
    expect(b.map(&:last)).not_to eq(a.map(&:last))
    clean = run_month(seed: 5, inject: ->(_) { [] })
    expect(run_month(seed: 6, inject: ->(_) { [] })).to eq(clean)
  end

  it 'targets each line at most once, and falls back to unknown_payment when the file runs out of lines' do
    sim = described_class.new
    3.times do |i|
      sim.submit('authorize', "k#{i}", { 'payment_method' => 'pm_card_visa', 'amount' => 100 + i,
                                         'currency' => 'usd', 'capture' => true }, t0)
    end
    file = sim.settlement_file(Date.new(2026, 3, 3), [{ 'random' => 8, 'seed' => 1, 'types' => ['duplicate'] }],
                               t0 + (2 * day))
    types = file.manifest['discrepancies'].map { |d| d['type'] }
    expect(types).to eq(%w[duplicate duplicate duplicate] + (%w[unknown_payment] * 5))
    expect(file.manifest['discrepancies'].first(3).map { |d| d['line_id'] }.uniq.size).to eq(3)
    expect(file.manifest['line_count']).to eq(3 + 3 + 5)
  end

  it 'refuses a malformed random spec' do
    sim = described_class.new
    [{ 'random' => -1 }, { 'random' => 'x' }, { 'random' => 1, 'types' => ['bogus'] },
     { 'random' => 1, 'types' => [] }].each do |spec|
      expect { sim.settlement_file(Date.new(2026, 3, 1), [spec], t0) }.to raise_error(AcquirerSim::RequestError)
    end
  end

  # Applies one random step: some traffic, and sometimes a settlement file with random
  # missing/late injections. Returns the file, if one was generated.
  def random_step(sim, refs, (kind, amount_draw, day_offset, inject_count), index, seed)
    at = t0 + (index * 6 * 3_600)
    if kind.zero? || refs.empty?
      refs << sim.submit('authorize', "a#{index}", { 'payment_method' => 'pm_card_visa', 'amount' => amount_draw + 1,
                                                     'currency' => 'usd', 'capture' => true }, at)
                 .operation.acquirer_reference
    elsif kind == 1
      sim.submit('refund', "r#{index}", { 'acquirer_reference' => refs[index % refs.size],
                                          'amount' => amount_draw + 1 }, at)
    end
    date = (at + (day_offset * day)).utc.to_date
    return if sim.stored_settlement_file(date) || kind != 3

    sim.settlement_file(date, [{ 'random' => inject_count, 'seed' => seed + index, 'types' => %w[missing late] }],
                        at + (day_offset * day))
  end

  # Counts each real line; returns the line ids a `missing` injection dropped. With
  # too few lines to target, random injection falls back to unknown_payment, whose
  # lines are not movements, so they are left out of the count.
  def tally(file, emitted)
    by_type = file.manifest['discrepancies'].group_by { |d| d['type'] }
    invented = (by_type['unknown_payment'] || []).map { |d| d['line_id'] }
    SettlementCsv.parse(file.csv).each { |row| emitted[row['line_id']] += 1 unless invented.include?(row['line_id']) }
    (by_type['missing'] || []).map { |d| d['line_id'] }
  end

  # The rule the reconciler depends on: every movement shows up in exactly one file
  # (or none, if a `missing` injection dropped it), however files and late
  # injections interleave with traffic.
  it 'emits every movement exactly once across files, under random traffic and random missing/late injections' do
    g = PropCheck::Generators
    step = g.tuple(g.choose(0..3), g.choose(0..4_999), g.choose(0..2), g.choose(0..3))
    PropCheck.forall(g.array(step, max: 30), g.choose(0..1_000)) do |steps, seed|
      sim = described_class.new
      refs = []
      emitted = Hash.new(0)
      dropped = []
      steps.each_with_index do |s, i|
        file = random_step(sim, refs, s, i, seed)
        dropped.concat(tally(file, emitted)) if file
      end
      # Settle everything still outstanding.
      tally(sim.settlement_file(Date.new(2026, 6, 1), [], Time.utc(2026, 6, 1)), emitted)

      expect(emitted.values.uniq - [1]).to be_empty
      expect(emitted.keys).to match_array(sim.movements.map(&:line_id) - dropped)
    end
  end
end
