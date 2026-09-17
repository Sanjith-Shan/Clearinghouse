# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Reconciliation
    # Renders a DataQuality::Report for a terminal, or as JSON for scripts.
    module DataQualityPrinter
      extend T::Sig

      sig { params(report: DataQuality::Report, limit: Integer).returns(String) }
      def self.render(report, limit: 20)
        clearing = report.clearing
        lines = ["Data quality as of #{clearing.as_of.utc.strftime('%Y-%m-%d %H:%M')} UTC", '']
        lines.concat(explainability(clearing))
        lines << ''
        lines.concat(past_sla(clearing, limit))
        lines << ''
        lines.concat(orphans(clearing))
        unless clearing.flow_types_without_sla.empty?
          lines << "Flow types with open flows and no SLA: #{clearing.flow_types_without_sla.join(', ')}"
        end
        lines << ''
        lines.concat(reconciliation(report))
        lines << ''
        lines << (report.healthy? ? 'HEALTHY' : 'NEEDS ATTENTION')
        "#{lines.join("\n")}\n"
      end

      sig { params(report: DataQuality::Report).returns(T::Hash[String, T.untyped]) }
      def self.to_h(report)
        clearing = report.clearing
        {
          'as_of' => clearing.as_of.utc.iso8601, 'healthy' => report.healthy?,
          'explainability' => clearing.explainability.map do |e|
            { 'flow_type' => e.flow_type, 'currency' => e.currency, 'flows' => e.flows,
              'explained_flows' => e.explained_flows, 'volume' => e.volume, 'explained_volume' => e.explained_volume,
              'share' => e.share.to_f.round(6) }
          end,
          'open_flows' => clearing.open_flows.length,
          'past_sla' => clearing.past_sla.map do |flow|
            { 'flow_id' => flow.flow_id, 'flow_type' => flow.flow_type, 'age_seconds' => flow.age_seconds,
              'sla_seconds' => flow.sla_seconds,
              'unexplained' => flow.unexplained.map do |(code, currency), net|
                { 'account' => code, 'currency' => currency, 'amount' => net }
              end }
          end,
          'orphan_balances' => clearing.orphan_balances.map do |o|
            { 'account' => o.code, 'currency' => o.currency, 'stored' => o.stored,
              'open_flows_total' => o.open_flows_total }
          end,
          'flow_types_without_sla' => clearing.flow_types_without_sla,
          'missing_raised' => report.missing_raised, 'open_exceptions' => report.open_exceptions,
          'pending_lines' => report.pending_lines
        }
      end

      sig { params(clearing: Ledger::Clearing::Report).returns(T::Array[String]) }
      def self.explainability(clearing)
        rows = clearing.explainability.map do |e|
          [e.flow_type, e.currency, e.flows.to_s, e.explained_flows.to_s, Money.of(e.volume, e.currency).to_s,
           Money.of(e.explained_volume, e.currency).to_s, percent(e.share)]
        end
        ['Explainability: share of volume in flows whose clearing accounts are back at zero'] +
          table(%w[flow currency flows explained volume explained_volume share], rows)
      end
      private_class_method :explainability

      sig { params(clearing: Ledger::Clearing::Report, limit: Integer).returns(T::Array[String]) }
      def self.past_sla(clearing, limit)
        overdue = clearing.past_sla
        return ["Open flows past SLA: none (#{clearing.open_flows.length} open within SLA)"] if overdue.empty?

        rows = overdue.first(limit).map do |flow|
          stuck = flow.unexplained.map { |(code, currency), net| "#{code} #{Money.of(net, currency)}" }.join('; ')
          [flow.flow_id, flow.flow_type, duration(flow.age_seconds), duration(T.must(flow.sla_seconds)), stuck]
        end
        more = overdue.length > limit ? ["  ... and #{overdue.length - limit} more"] : []
        ["Open flows past SLA: #{overdue.length}"] + table(%w[flow type open_for sla stuck], rows) + more
      end
      private_class_method :past_sla

      sig { params(clearing: Ledger::Clearing::Report).returns(T::Array[String]) }
      def self.orphans(clearing)
        return ['Orphan clearing balances: none'] if clearing.orphan_balances.empty?

        rows = clearing.orphan_balances.map do |o|
          [o.code, Money.of(o.stored, o.currency).to_s, Money.of(o.open_flows_total, o.currency).to_s,
           Money.of(o.unexplained, o.currency).to_s]
        end
        ['Orphan clearing balances (stored balance not explained by open flows)'] +
          table(%w[account stored open_flows unexplained], rows)
      end
      private_class_method :orphans

      sig { params(report: DataQuality::Report).returns(T::Array[String]) }
      def self.reconciliation(report)
        open = report.open_exceptions.sort.map { |reason, count| "#{reason} #{count}" }
        lines = ["Open reconciliation exceptions: #{open.empty? ? 'none' : open.join(', ')}",
                 "Settlement lines waiting for their flow: #{report.pending_lines}"]
        raised = report.missing_raised
        noun = raised.length == 1 ? 'exception' : 'exceptions'
        ids = raised.empty? ? '' : ": #{raised.join(', ')}"
        lines << "Raised #{raised.length} new missing #{noun}#{ids}"
        lines
      end
      private_class_method :reconciliation

      sig { params(headers: T::Array[String], rows: T::Array[T::Array[String]]).returns(T::Array[String]) }
      def self.table(headers, rows)
        return ['  (none)'] if rows.empty?

        widths = headers.each_index.map { |i| ([headers[i]] + rows.map { |r| r[i] }).map { |c| c.to_s.length }.max }
        [headers, *rows].map do |row|
          "  #{row.each_with_index.map { |c, i| c.to_s.ljust(T.must(widths[i])) }.join('  ').rstrip}"
        end
      end
      private_class_method :table

      sig { params(share: Rational).returns(String) }
      def self.percent(share)
        # Truncated, never rounded up: 99.995% must not print as 100.00%.
        basis = (share * 10_000).floor
        format('%<whole>d.%<frac>02d%%', whole: basis / 100, frac: basis % 100)
      end

      sig { params(seconds: Integer).returns(String) }
      def self.duration(seconds)
        days, rest = seconds.divmod(DataQuality::DAY)
        hours = rest / 3600
        days.positive? ? "#{days}d #{hours}h" : "#{hours}h"
      end
    end
  end
end
