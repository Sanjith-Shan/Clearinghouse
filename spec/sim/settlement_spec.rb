# typed: false
# frozen_string_literal: true

require 'securerandom'
require_relative 'sim_helper'

RSpec.describe AcquirerSim::App do
  include SimHelper

  let(:day) { 86_400 }
  let(:t0) { SimHelper::T0 } # 2026-03-01 12:00 UTC

  def settle(date, inject: nil, at: nil)
    at ||= Time.utc(*date.split('-').map(&:to_i)) + 3_600
    call(:post, '/settlement_files', { date: date, inject: inject }.compact, at: at)
  end

  def lines(date, **)
    response = settle(date, **)
    raise "settlement #{date}: #{response.status} #{response.body}" unless response.status == 200

    SettlementCsv.parse(response.body)
  end

  def manifest(date)
    json_body(call(:get, "/admin/settlement_files/#{date}/manifest"))
  end

  def capture!(amount: 10_000, currency: 'usd', payment_method: 'pm_card_visa', at: t0)
    authorize!(amount: amount, currency: currency, payment_method: payment_method, capture: true, at: at)
  end

  describe 'lines' do
    it 'settles a capture settlement_lag_days after it happened, gross amount and the acquirer fee' do
      op = capture!
      response = settle('2026-03-03')
      expect(response.headers['Content-Type']).to start_with('text/csv')
      expect(response.headers['Settlement-Manifest']).to eq('/admin/settlement_files/2026-03-03/manifest')
      expect(response.body.lines.first.chomp)
        .to eq('line_id,type,acquirer_reference,operation_id,amount,fee,currency,settled_on')
      expect(SettlementCsv.parse(response.body)).to match(
        [{ 'line_id' => a_string_matching(/\Aln_\h{24}\z/), 'type' => 'capture',
           'acquirer_reference' => op['acquirer_reference'], 'operation_id' => op['id'], 'amount' => '10000',
           'fee' => '160', 'currency' => 'usd', 'settled_on' => '2026-03-03' }]
      )
    end

    it 'puts nothing in the files before the lag has passed' do
      capture!
      expect(lines('2026-03-01')).to be_empty
      expect(lines('2026-03-02')).to be_empty
      expect(lines('2026-03-03').size).to eq(1)
    end

    it 'settles a manual capture from its capture date and a refund as a negative line with no fee' do
      ref = authorize!(amount: 10_000)['acquirer_reference']
      post_json('/capture', { acquirer_reference: ref, amount: 8_000 }, at: t0 + day)
      post_json('/refund', { acquirer_reference: ref, amount: 3_000 }, at: t0 + (2 * day))
      expect(lines('2026-03-03')).to be_empty
      expect(lines('2026-03-04').map { |l| l.values_at('type', 'amount', 'fee') }).to eq([%w[capture 8000 130]])
      expect(lines('2026-03-05').map { |l| l.values_at('type', 'amount', 'fee') }).to eq([%w[refund -3000 0]])
    end

    it 'debits a dispute when it opens and credits a won dispute when it closes' do
      ref = capture!(payment_method: 'pm_card_disputeFraudulent')['acquirer_reference']
      call(:post, "/admin/disputes/#{simulator.disputes.first.id}/resolve", { outcome: 'won' }, at: t0 + (9 * day))
      (1..9).each { |d| lines(format('2026-03-%02d', d)) }
      dispute = lines('2026-03-10')
      expect(dispute.map { |l| l.values_at('type', 'acquirer_reference', 'amount', 'fee') })
        .to eq([['dispute', ref, '-10000', '0']])
      expect(dispute.first['operation_id']).to eq(simulator.disputes.first.id)
      expect(lines('2026-03-11')).to be_empty
      expect(lines('2026-03-12').map { |l| l.values_at('type', 'amount') }).to eq([%w[dispute_reversal 10000]])
    end

    it 'does not credit a lost dispute' do
      capture!(payment_method: 'pm_card_disputeFraudulent')
      call(:post, "/admin/disputes/#{simulator.disputes.first.id}/resolve", { outcome: 'lost' }, at: t0 + (8 * day))
      expect(simulator.movements.map(&:type)).to eq(%w[capture dispute])
    end

    it 'follows a configured lag' do
      simulator.configure('settlement_lag_days' => 0)
      capture!
      # Same day, but only once the caller's clock has passed the capture itself.
      expect(settle('2026-03-01', at: t0 - 1).body.lines.size).to eq(1)
      expect(call(:get, '/settlement_files/2026-03-01').status).to eq(200)
      expect(lines('2026-03-02').size).to eq(1)
    end
  end

  describe 'the acquirer fee' do
    it 'rounds the percentage half to even in minor units of each currency' do
      # 1.5% of 100 is 1.5 -> 2, of 300 is 4.5 -> 4 (ties go to even), each plus 10 minor units.
      capture!(amount: 100)
      capture!(amount: 300)
      capture!(amount: 500, currency: 'jpy') # 7.5 yen -> 8 yen, plus 10 yen
      capture!(amount: 1_234, currency: 'kwd') # 18.51 fils -> 19, plus 10 fils
      fees = lines('2026-03-03').to_h { |l| [[l['amount'], l['currency']], l['fee']] }
      expect(fees).to eq(%w[100 usd] => '12', %w[300 usd] => '14', %w[500 jpy] => '18', %w[1234 kwd] => '29')
    end

    it 'takes a configured rate and a per-currency fixed part' do
      simulator.configure('fee' => { 'rate_scaled' => 290_000, 'fixed' => { 'default' => 30, 'jpy' => 0 } })
      capture!(amount: 10_000)
      capture!(amount: 10_000, currency: 'jpy')
      fees = lines('2026-03-03').to_h { |l| [l['currency'], l['fee']] }
      expect(fees).to eq('usd' => '320', 'jpy' => '290')
      expect(simulator.config.to_h['fee']).to eq('rate_scaled' => 290_000, 'fixed' => { 'jpy' => 0, 'default' => 30 })
    end

    it 'takes a plain integer fixed part, which replaces any per-currency ones' do
      simulator.configure('fee' => { 'fixed' => { 'default' => 1, 'jpy' => 0 } })
      simulator.configure('fee' => { 'fixed' => 0 })
      capture!(amount: 10_000, currency: 'jpy')
      expect(lines('2026-03-03').map { |l| l['fee'] }).to eq(['150'])
      expect(simulator.config.to_h['fee']).to eq('rate_scaled' => 150_000, 'fixed' => 0)
    end

    it 'refuses a nonsense fee config' do
      [{ rate_scaled: -1 }, { rate_scaled: 10_000_001 }, { fixed: -1 }, { fixed: { 'xyz' => 1 } }, 5].each do |fee|
        expect(call(:post, '/admin/config', { fee: fee }).status).to eq(400), fee.inspect
      end
    end
  end

  describe 'files' do
    it 'freezes a file: the same request returns the same bytes, a different injection is refused' do
      capture!
      first = settle('2026-03-03').body
      expect(settle('2026-03-03', at: t0 + (30 * day)).body).to eq(first)
      conflict = settle('2026-03-03', inject: [{ type: 'unknown_payment' }])
      expect(conflict.status).to eq(409)
      expect(json_body(conflict)['error']).to eq('settlement_file_exists')
      expect(call(:get, '/settlement_files/2026-03-03').body).to eq(first)
    end

    it 'carries a straggler that arrives after its file was generated into the next file, and says so' do
      expect(lines('2026-03-03')).to be_empty
      op = capture!(at: t0) # a caller with a lagging clock captures "on 1 March" after the 3 March file exists
      next_file = lines('2026-03-04')
      expect(next_file.map { |l| l['acquirer_reference'] }).to eq([op['acquirer_reference']])
      expect(manifest('2026-03-04')['carried_over'])
        .to match([a_hash_including('acquirer_reference' => op['acquirer_reference'], 'due_on' => '2026-03-03',
                                    'injected_late' => false)])
    end

    it 'refuses a date the caller has not reached, a bad date, and a missing Sim-Time' do
      expect(json_body(settle('2026-03-05', at: t0))['error']).to eq('settlement_date_in_future')
      expect(settle('2026-02-30').status).to eq(400)
      expect(call(:post, '/settlement_files', { date: '2026-03-01' }, at: nil).status).to eq(400)
      expect(call(:get, '/settlement_files/2026-03-09').status).to eq(404)
      expect(call(:get, '/admin/settlement_files/2026-03-09/manifest').status).to eq(404)
    end
  end

  describe 'injected discrepancies' do
    let!(:refs) { Array.new(3) { |i| capture!(amount: 1_000 * (i + 1))['acquirer_reference'] } }

    it 'missing: drops the line, and it never turns up later' do
      file = lines('2026-03-03', inject: [{ type: 'missing', acquirer_reference: refs[0] }])
      expect(file.map { |l| l['acquirer_reference'] }).to match_array(refs[1..])
      expect((4..10).flat_map { |d| lines(format('2026-03-%02d', d)) }).to be_empty
      expect(manifest('2026-03-03')['discrepancies'])
        .to match([a_hash_including('type' => 'missing', 'acquirer_reference' => refs[0], 'line_type' => 'capture',
                                    'expected' => { 'amount' => 1_000, 'fee' => 25 })])
    end

    it 'duplicate: the same line_id and reference twice' do
      dupes = lines('2026-03-03', inject: [{ type: 'duplicate', acquirer_reference: refs[1] }])
              .select { |l| l['acquirer_reference'] == refs[1] }
      expect(dupes.size).to eq(2)
      expect(dupes.uniq.size).to eq(1)
    end

    it 'amount_mismatch and fee_mismatch: change the line by delta and record both values' do
      inject = [{ type: 'amount_mismatch', acquirer_reference: refs[0], delta: 7 },
                { type: 'fee_mismatch', acquirer_reference: refs[1] }]
      file = lines('2026-03-03', inject: inject).to_h { |l| [l['acquirer_reference'], l.values_at('amount', 'fee')] }
      expect(file[refs[0]]).to eq(%w[1007 25])
      expect(file[refs[1]]).to eq(%w[2000 41])
      expect(manifest('2026-03-03')['discrepancies'].map { |d| [d['type'], d['expected'], d['actual']] }).to eq(
        [['amount_mismatch', { 'amount' => 1_000, 'fee' => 25 }, { 'amount' => 1_007, 'fee' => 25 }],
         ['fee_mismatch', { 'amount' => 2_000, 'fee' => 40 }, { 'amount' => 2_000, 'fee' => 41 }]]
      )
    end

    it 'amount_mismatch on a refund makes it larger in magnitude, never flips its sign' do
      post_json('/refund', { acquirer_reference: refs[2], amount: 500 }, at: t0 + day)
      lines('2026-03-03')
      refund = lines('2026-03-04', inject: [{ type: 'amount_mismatch', acquirer_reference: refs[2], delta: 3 }])
      expect(refund.map { |l| l['amount'] }).to eq(['-503'])
    end

    it 'late: moves the line to a later file, where it appears exactly once' do
      file = lines('2026-03-03', inject: [{ type: 'late', acquirer_reference: refs[0] }])
      expect(file.map { |l| l['acquirer_reference'] }).not_to include(refs[0])
      expect(manifest('2026-03-03')['discrepancies'].first).to include('type' => 'late', 'deferred_to' => '2026-03-04')

      later = lines('2026-03-04')
      expect(later.map { |l| l.values_at('acquirer_reference', 'settled_on') }).to eq([[refs[0], '2026-03-04']])
      expect(manifest('2026-03-04')['carried_over'])
        .to match([a_hash_including('acquirer_reference' => refs[0], 'due_on' => '2026-03-03',
                                    'injected_late' => true)])
      expect(lines('2026-03-05')).to be_empty
    end

    it 'late by several days skips the files in between' do
      lines('2026-03-03', inject: [{ type: 'late', acquirer_reference: refs[0], days: 3 }])
      expect(lines('2026-03-04')).to be_empty
      expect(lines('2026-03-05')).to be_empty
      expect(lines('2026-03-06').map { |l| l['acquirer_reference'] }).to eq([refs[0]])
    end

    it 'targets a refund line rather than the capture when line_type says so' do
      post_json('/refund', { acquirer_reference: refs[0], amount: 100 }, at: t0 - 3_600)
      lines('2026-03-03', inject: [{ type: 'missing', acquirer_reference: refs[0], line_type: 'refund' }])
      expect(manifest('2026-03-03')['discrepancies'].first['line_type']).to eq('refund')
    end

    it 'unknown_payment: a capture for a reference the acquirer never authorized' do
      extra = lines('2026-03-03', inject: [{ type: 'unknown_payment', amount: 4_321, currency: 'eur' }])
              .reject { |l| refs.include?(l['acquirer_reference']) }
      expect(extra.size).to eq(1)
      line = extra.first
      expect(line).to include('type' => 'capture', 'amount' => '4321', 'currency' => 'eur', 'fee' => '75')
      expect(line['acquirer_reference']).to match(/\Aacq_\h{24}\z/)
      expect(simulator.authorizations.map(&:acquirer_reference)).not_to include(line['acquirer_reference'])
      expect(manifest('2026-03-03')['discrepancies'].first)
        .to include('type' => 'unknown_payment', 'acquirer_reference' => line['acquirer_reference'])
    end

    it 'refuses a target not in the file, a line targeted twice, and an unknown type, and changes nothing' do
      missing = settle('2026-03-03', inject: [{ type: 'missing', acquirer_reference: 'acq_nope' }])
      expect([missing.status, json_body(missing)['error']]).to eq([422, 'discrepancy_target_not_found'])
      twice = settle('2026-03-03', inject: [{ type: 'missing', acquirer_reference: refs[0] },
                                            { type: 'late', acquirer_reference: refs[0] }])
      expect([twice.status, json_body(twice)['error']]).to eq([422, 'discrepancy_conflict'])
      expect(settle('2026-03-03', inject: [{ type: 'teleport' }]).status).to eq(400)
      expect(settle('2026-03-03', inject: 'missing').status).to eq(400)
      expect(lines('2026-03-03').size).to eq(3)
    end
  end
end
