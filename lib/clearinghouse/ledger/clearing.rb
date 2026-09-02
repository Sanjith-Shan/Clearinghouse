# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    # The data-quality report, modelled on the clearing checks in Stripe's Ledger
    # post. Every flow routes money through clearing accounts that must net back to
    # zero once the flow completes. A flow is *explained* when every clearing
    # account it touched nets to zero within that flow's own transactions. The
    # report never needs to know what a bug looks like: money that moved and did
    # not come back shows up as an unexplained flow.
    module Clearing
      extend T::Sig

      ClearingKey = T.type_alias { [String, String] } # [code, currency]

      # A flow with at least one clearing account not back at zero.
      class OpenFlow < T::Struct
        extend T::Sig

        const :flow_id, String
        const :flow_type, String
        const :opened_at, Time
        const :age_seconds, Integer
        const :sla_seconds, T.nilable(Integer)
        # Net per clearing account, signed on that account's normal side.
        const :unexplained, T::Hash[ClearingKey, Integer]

        # False when no SLA is configured for the flow type; those flows are
        # listed under Report#flow_types_without_sla instead.
        sig { returns(T::Boolean) }
        def past_sla?
          sla = sla_seconds
          !sla.nil? && age_seconds > sla
        end
      end

      # A clearing account whose stored balance is not accounted for by the open
      # flows behind it.
      class OrphanBalance < T::Struct
        extend T::Sig

        const :code, String
        const :currency, String
        const :stored, Integer
        const :open_flows_total, Integer

        sig { returns(Integer) }
        def unexplained
          stored - open_flows_total
        end
      end

      # Share of volume, per flow type and currency, in flows that fully cleared.
      # A flow's volume is the sum of the debits in its first transaction: the
      # amount the flow set out to move.
      class Explainability < T::Struct
        extend T::Sig

        const :flow_type, String
        const :currency, String
        const :flows, Integer
        const :explained_flows, Integer
        const :volume, Integer
        const :explained_volume, Integer

        sig { returns(Rational) }
        def share
          volume.zero? ? Rational(1) : Rational(explained_volume, volume)
        end
      end

      # Everything one run found. `open_flows` holds every unexplained flow,
      # in progress or not; `past_sla` is the subset that is overdue.
      class Report < T::Struct
        extend T::Sig

        const :as_of, Time
        const :open_flows, T::Array[OpenFlow]
        const :orphan_balances, T::Array[OrphanBalance]
        const :explainability, T::Array[Explainability]
        const :flow_types_without_sla, T::Array[String]

        sig { returns(T::Array[OpenFlow]) }
        def past_sla
          open_flows.select(&:past_sla?)
        end

        sig { returns(T::Boolean) }
        def healthy?
          past_sla.empty? && orphan_balances.empty?
        end
      end

      FLOW_NETS = <<~SQL
        SELECT t.flow_id, a.code, a.currency,
               sum(CASE WHEN e.side = a.normal_side THEN e.amount ELSE -e.amount END) AS net
          FROM ledger_entries e
          JOIN ledger_transactions t ON t.id = e.transaction_id
          JOIN ledger_accounts a ON a.id = e.account_id
         WHERE a.kind = 'clearing'
         GROUP BY t.flow_id, a.code, a.currency
        HAVING sum(CASE WHEN e.side = a.normal_side THEN e.amount ELSE -e.amount END) <> 0
         ORDER BY t.flow_id, a.code, a.currency
      SQL

      FLOW_VOLUMES = <<~SQL
        WITH first_txn AS (
          SELECT DISTINCT ON (flow_id) flow_id, id, flow_type, effective_at
            FROM ledger_transactions ORDER BY flow_id, effective_at, id
        )
        SELECT f.flow_id, f.flow_type, f.effective_at AS opened_at, e.currency, sum(e.amount) AS volume
          FROM first_txn f JOIN ledger_entries e ON e.transaction_id = f.id AND e.side = 'D'
         GROUP BY f.flow_id, f.flow_type, f.effective_at, e.currency
         ORDER BY f.flow_id, e.currency
      SQL

      CLEARING_BALANCES = <<~SQL
        SELECT a.code, a.currency, b.balance
          FROM ledger_accounts a JOIN account_balances b ON b.account_id = a.id
         WHERE a.kind = 'clearing' ORDER BY a.code, a.currency
      SQL

      # `slas` maps flow_type to the seconds a flow of that type may stay open.
      # `as_of` is the simulated time the report is taken at; it decides ages.
      sig { params(db: Sequel::Database, as_of: Time, slas: T::Hash[String, Integer]).returns(Report) }
      def self.report(db, as_of:, slas:)
        nets = flow_nets(db)
        flows = flow_summaries(db)
        open = nets.keys.sort.map do |flow_id|
          flow = flows.fetch(flow_id)
          OpenFlow.new(flow_id: flow_id, flow_type: flow.flow_type, opened_at: flow.opened_at,
                       age_seconds: (as_of - flow.opened_at).floor, sla_seconds: slas[flow.flow_type],
                       unexplained: nets.fetch(flow_id))
        end
        Report.new(as_of: as_of, open_flows: open, orphan_balances: orphans(db, nets),
                   explainability: explainability(flows, nets),
                   flow_types_without_sla: open.map(&:flow_type).uniq.reject { |t| slas.key?(t) }.sort)
      end

      sig { params(db: Sequel::Database).returns(T::Hash[String, T::Hash[ClearingKey, Integer]]) }
      def self.flow_nets(db)
        nets = T.let({}, T::Hash[String, T::Hash[ClearingKey, Integer]])
        db.fetch(FLOW_NETS).each do |row|
          (nets[row.fetch(:flow_id)] ||= {})[[row.fetch(:code), row.fetch(:currency)]] = Integer(row.fetch(:net))
        end
        nets
      end
      private_class_method :flow_nets

      # What the report needs to know about one flow, from its first transaction.
      class FlowSummary < T::Struct
        const :flow_type, String
        const :opened_at, Time
        const :volumes, T::Hash[String, Integer] # currency => minor units
      end
      private_constant :FlowSummary

      sig { params(db: Sequel::Database).returns(T::Hash[String, FlowSummary]) }
      def self.flow_summaries(db)
        db.fetch(FLOW_VOLUMES).all.group_by { |row| row.fetch(:flow_id) }.transform_values do |rows|
          first = rows.fetch(0)
          FlowSummary.new(flow_type: first.fetch(:flow_type), opened_at: first.fetch(:opened_at),
                          volumes: rows.to_h { |row| [row.fetch(:currency), Integer(row.fetch(:volume))] })
        end
      end
      private_class_method :flow_summaries

      sig do
        params(db: Sequel::Database, nets: T::Hash[String, T::Hash[ClearingKey, Integer]])
          .returns(T::Array[OrphanBalance])
      end
      def self.orphans(db, nets)
        behind = T.let({}, T::Hash[ClearingKey, Integer])
        nets.each_value { |by_account| by_account.each { |key, net| behind[key] = behind.fetch(key, 0) + net } }
        db.fetch(CLEARING_BALANCES).filter_map do |row|
          key = [row.fetch(:code), row.fetch(:currency)]
          stored = Integer(row.fetch(:balance))
          next if stored == behind.fetch(key, 0)

          OrphanBalance.new(code: key[0], currency: key[1], stored: stored, open_flows_total: behind.fetch(key, 0))
        end
      end
      private_class_method :orphans

      sig do
        params(flows: T::Hash[String, FlowSummary], nets: T::Hash[String, T::Hash[ClearingKey, Integer]])
          .returns(T::Array[Explainability])
      end
      def self.explainability(flows, nets)
        # [flow_type, currency, volume, explained?] per flow and currency
        rows = flows.flat_map do |flow_id, flow|
          flow.volumes.map { |currency, volume| [flow.flow_type, currency, volume, !nets.key?(flow_id)] }
        end
        rows.group_by { |row| [row[0], row[1]] }.sort.map do |(flow_type, currency), group|
          explained = group.select(&:last)
          Explainability.new(flow_type: flow_type, currency: currency, flows: group.length,
                             explained_flows: explained.length, volume: group.sum { |row| row[2] },
                             explained_volume: explained.sum { |row| row[2] })
        end
      end
      private_class_method :explainability
    end
  end
end
