# typed: true
# frozen_string_literal: true

require 'json'

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): the report.
  module CrashMatrix
    MACHINE = 'Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker'

    NORMALISATION = <<~TEXT
      The recovered response is compared with an uninterrupted control request (same scenario, another
      Idempotency-Key, same server, same database) after rewriting exactly two things: generated ids
      (prefix_ plus 24 alphanumerics, the simulator's acq_ plus 24 hex, and the fake RiskGate's asm_
      counter) become <prefix#n> numbered by first appearance, so references must still line up; and the value of every key named `created`
      (the Unix second the object was created). Status, every amount, state, error code, and key order
      must match exactly. The second retry of the crashed request is compared with the recovered response
      byte for byte, with no normalisation at all. The outcome (intent, refunds, events with their payloads,
      ledger, acquirer operations) is compared with the control's under the same id rule, including which
      request's Idempotency-Key each event carries.
    TEXT

    # 1, 5 and 15 minute load averages.
    sig { returns(T::Array[Float]) }
    def self.load_average
      if File.exist?('/proc/loadavg')
        File.read('/proc/loadavg').split.first(3).map(&:to_f)
      else
        IO.popen(%w[sysctl -n vm.loadavg], &:read).to_s.scan(/[\d.]+/).first(3).map(&:to_f)
      end
    end

    # The headline, with K and M computed from what ran. Only a full run (every
    # registry point) may claim it.
    sig { params(results: T::Array[CaseResult], full: T::Boolean).returns(String) }
    def self.headline(results, full:)
      points = results.select { |r| r.kase.variant.nil? }
      k = points.length
      m = points.map { |r| r.kase.flow }.uniq.length
      recovered = points.count(&:passed?)
      prefix = full ? '' : 'PARTIAL RUN (not the whole registry): '
      crashed = "#{prefix}crashed at #{k} point#{'s' unless k == 1} across #{m} flow#{'s' unless m == 1}"
      recovered == k ? "#{crashed}, recovered at all #{k}" : "#{crashed}, recovered at #{recovered} of #{k}"
    end

    sig do
      params(results: T::Array[CaseResult], meta: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped])
    end
    def self.report(results, meta)
      meta.merge(
        'headline' => headline(results, full: meta.fetch('full_matrix')),
        'normalisation' => NORMALISATION.tr("\n", ' ').strip,
        'passed' => results.count(&:passed?), 'failed' => results.count { |r| !r.passed? },
        'cases' => results.map do |r|
          { 'name' => r.kase.name, 'flow' => r.kase.flow, 'point' => r.kase.point, 'moment' => r.kase.moment.to_s,
            'variant' => r.kase.variant, 'passed' => r.passed?, 'error' => r.error, 'timings' => r.timings,
            'checks' => r.checks.map(&:serialize), 'recovery' => r.recovery, 'acquirer_exchanges' => r.exchanges }
        end
      )
    end

    sig { params(report: T::Hash[String, T.untyped]).returns(String) }
    def self.markdown(report)
      lines = ["# Experiment 2: crash at every recovery point (#{report['recovery_mode']} mode)", '',
               "**#{report['headline']}.**", '', *header_lines(report), '',
               "Normalisation: #{report['normalisation']}", '', *table_lines(report), *failure_lines(report)]
      "#{lines.join("\n")}\n"
    end

    sig { params(report: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def self.header_lines(report)
      load = report.fetch('load_average')
      missing = Array(report['flows_without_scenario'])
      api = report['api_process'] || {}
      ["- Command: `#{report['command']}` at commit #{report['git'] || 'not recorded'}",
       "- Machine: #{report['machine']} (server #{report['postgres']})",
       "- API process: Puma single mode, threads #{api['puma_threads']}, database pool #{api['db_pool']}",
       "- Load average (1/5/15 min): before #{load['before'].join(' / ')}, after #{load['after'].join(' / ')}",
       "- Started #{report['started_at']}, took #{report['duration_s']} s; lease (lock timeout) " \
       "#{report['lock_timeout_s']} s",
       "- Registry: #{report['registry_crash_points']} crash points in #{report['registry_flows'].length} flows " \
       "(#{report['registry_flows'].join(', ')})",
       "- Flows with no scenario yet (their cases fail): #{missing.empty? ? 'none' : missing.join(', ')}"]
    end

    sig { params(report: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def self.table_lines(report)
      rows = report.fetch('cases').each_with_index.map do |c, i|
        failed = c['checks'].reject { |ch| ch['ok'] }.map { |ch| ch['name'] }
        failed << "error: #{c['error']}" if c['error']
        answer = c['recovery'].last.to_s.sub(/\Aretry \d+: /, '')
        "| #{i + 1} | `#{c['name']}` | #{c['passed'] ? 'pass' : '**FAIL**'} | #{answer} | " \
          "#{c.dig('timings', 'total_s')} | #{failed.join(', ')} |"
      end
      ['| # | Crash name | Result | Recovered answer | Total s | Failed checks |', '|---|---|---|---|---|---|', *rows]
    end

    sig { params(report: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def self.failure_lines(report)
      failures = report.fetch('cases').reject { |c| c['passed'] }
      return [] if failures.empty?

      ['', '## Failures', ''] + failures.flat_map do |c|
        ["### `#{c['name']}`", *(c['error'] ? ["- error: #{c['error']}"] : []),
         *c['checks'].reject { |ch| ch['ok'] }.map { |ch| "- #{ch['name']}: #{ch['detail'][0, 600]}" },
         "- recovery: #{c['recovery'].join('; ')}", '']
      end
    end
  end
end
