# typed: true
# frozen_string_literal: true

require_relative '../../lib/clearinghouse'
require_relative 'replay/rows'
require_relative 'replay/tally'
require_relative 'replay/stack'
require_relative 'replay/runner'

module Experiments
  # Experiment 8 (RiskGate's spec) and Clearinghouse M6: RiskGate's test-month replay
  # through Clearinghouse's API, with Clearinghouse calling RiskGate on every confirm,
  # under three policies (no checks, the model threshold alone, model plus rules).
  # Fraud-labelled rows pay with the simulator's disputing card, so their disputes
  # open in simulated time and flow back to RiskGate by webhook as labels.
  # docs/design/replay.md.
  #
  # The transactions are real (IEEE-CIS, read in place); everything around them is
  # simulated: the acquirer, the disputes, the clock, and the 15.00 USD dispute fee,
  # which is an assumption.
  module Replay
    extend T::Sig

    MACHINE = 'Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker'

    # The report as Markdown. Aggregates only, like the JSON.
    sig { params(report: T::Hash[String, T.untyped]).returns(String) }
    def self.markdown(report)
      money = report.fetch('money')
      lines = ["# Experiment 8 replay: policy `#{report['policy']}` (#{report['label']})", '',
               *provenance(report), '', '## Money (USD)', '',
               '| | count | volume |', '|---|---|---|']
      [%w[payments payments], %w[approved approved], %w[blocked blocked], %w[reviews reviews],
       %w[risk_unavailable risk_unavailable], %w[declined_or_error declined_or_error],
       ['fraud caught (is_fraud=1 blocked)', 'fraud_caught'], ['fraud through', 'fraud_through'],
       ['legitimate revenue blocked (is_fraud=0 blocked)', 'legit_blocked']].each do |label, key|
        next lines << "| #{label} | #{money.fetch(key)} | |" if key == 'payments'

        b = money.fetch(key)
        lines << "| #{label} | #{b['count']} | #{usd(b['volume_cents'])} |"
      end
      disputes = money.fetch('disputes')
      fee = money.fetch('dispute_fee_cents_assumed')
      net = money.fetch('net')
      lines.push(
        "| disputes (source: #{report['disputes_source']}) | #{disputes['count']} | " \
        "#{usd(disputes['volume_cents'])} |", '',
        "Dispute losses: **#{usd(money['dispute_losses_cents'])}** = disputed amount plus an **assumed** " \
        "#{usd(fee)} fee per dispute.", '',
        "Net of fraud checks: saved #{usd(net['saved_cents'])} (blocked fraud plus the assumed fee each would " \
        "have cost) minus #{usd(net['cost_cents'])} of legitimate revenue blocked = **#{usd(net['net_cents'])}**.",
        ''
      )
      (lines + latency_lines(report.fetch('latency')) + [''] + system_lines(report)).join("\n")
    end

    sig { params(report: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def self.provenance(report)
      load = report['load_average'] || {}
      sim = report.fetch('simulated')
      risk = report.fetch('riskgate')
      ["Command: `#{report['command']}`", '',
       "Machine: #{report['machine']}. Load average (1/5/15 min) before #{Array(load['before']).join('/')}, " \
       "after #{Array(load['after']).join('/')}.", '',
       "Replay file: #{report['replay_file']} (read in place; no rows are stored), #{report['rows']} rows, " \
       "seed #{report.dig('plan', 'seed')}. Simulated time #{sim['first_created']} to #{sim['clock_at_end']}; " \
       "#{sim['rows_created_at_a_later_time']} rows out of time order.", '',
       "RiskGate: #{risk['kind'] || 'none'} at #{risk['url'] || '-'}, ruleset #{risk['ruleset_version'] || '-'} " \
       "(seen on decisions: #{risk['ruleset_versions_seen']}), deadline #{risk['deadline_ms']} ms."]
    end

    sig { params(latency: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def self.latency_lines(latency)
      confirm = latency.fetch('confirm_ms')
      risk = latency.fetch('risk_step_ms')
      share = latency['risk_share_of_confirm']
      ['## Latency', '',
       "Confirm, as the client saw it: p50 #{confirm['p50'] || '-'} ms, p99 #{confirm['p99'] || '-'} ms " \
       "(n=#{confirm['n']}). Risk step inside it: p50 #{risk['p50'] || '-'} ms, p99 #{risk['p99'] || '-'} ms " \
       "(n=#{risk['n']}), #{share ? "#{(share * 100).round(1)}% of confirm time" : 'not called'}. " \
       'Smoke-run latencies on a shared machine are not publishable numbers.']
    end

    sig { params(report: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def self.system_lines(report)
      holds = report.fetch('holds')
      hooks = report.fetch('webhooks')
      delivered = hooks.fetch('deliveries', {}).map { |type, s| "#{type} #{s}" }.join('; ')
      webhooks = if hooks['registered']
                   "registered, workers ran: #{hooks['workers_ran']}, drained: #{hooks['drained']}. #{delivered}"
                 else
                   'not registered'
                 end
      ['## The rest of the system', '',
       "Review holds opened: #{holds['opened']} (#{usd(holds['amount_cents'])} captured under review, " \
       "#{usd(holds['held_cents'])} of merchant net held).",
       "Webhooks to RiskGate: #{webhooks}.",
       "Scheduler step errors: #{report['scheduler_step_errors']}. " \
       "Ledger invariant violations: #{report['ledger_invariant_violations']}."]
    end
  end
end
