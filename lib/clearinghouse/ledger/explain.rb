# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    # A trace of one flow: every transaction and entry in order, and the running
    # net of each clearing account the flow has touched. It answers "where is
    # this money right now, and why" for a single payment, refund, dispute or
    # payout.
    module Explain
      extend T::Sig

      ClearingKey = T.type_alias { [String, String] } # [code, currency]

      class FlowNotFoundError < Ledger::Error; end

      # One entry, with its account's code and kind.
      class Line < T::Struct
        const :account, String
        const :kind, Symbol
        const :side, Symbol
        const :amount, Money
      end

      # One transaction and the clearing state right after it.
      class Step < T::Struct
        const :transaction_id, Integer
        const :description, String
        const :effective_at, Time
        const :reverses_transaction_id, T.nilable(Integer)
        const :reversed_by, T.nilable(Integer)
        const :lines, T::Array[Line]
        # Running net of every clearing account touched so far, including ones
        # back at zero, signed on each account's normal side.
        const :clearing_after, T::Hash[ClearingKey, Integer]
      end

      # The whole flow.
      class Explanation < T::Struct
        extend T::Sig

        const :flow_id, String
        const :flow_type, String
        const :steps, T::Array[Step]

        sig { returns(T::Hash[ClearingKey, Integer]) }
        def clearing
          steps.last&.clearing_after || {}
        end

        # Every clearing account the flow touched is back at zero.
        sig { returns(T::Boolean) }
        def explained?
          clearing.values.all?(&:zero?)
        end
      end

      QUERY = <<~SQL
        SELECT t.id, t.flow_type, t.description, t.effective_at, t.reverses_transaction_id,
               r.id AS reversed_by, a.code, a.kind, a.normal_side, e.side, e.amount, e.currency
          FROM ledger_transactions t
          JOIN ledger_entries e ON e.transaction_id = t.id
          JOIN ledger_accounts a ON a.id = e.account_id
          LEFT JOIN ledger_transactions r ON r.reverses_transaction_id = t.id
         WHERE t.flow_id = ?
         ORDER BY t.effective_at, t.id, e.id
      SQL

      sig { params(db: Sequel::Database, flow_id: String).returns(Explanation) }
      def self.run(db, flow_id)
        rows = db.fetch(QUERY, flow_id).all
        raise FlowNotFoundError, "no ledger transactions for flow #{flow_id.inspect}" if rows.empty?

        clearing = T.let({}, T::Hash[ClearingKey, Integer])
        steps = rows.chunk_while { |a, b| a.fetch(:id) == b.fetch(:id) }.map do |txn_rows|
          txn_rows.each { |row| accumulate(clearing, row) }
          step(txn_rows, clearing.dup)
        end
        Explanation.new(flow_id: flow_id, flow_type: rows.fetch(0).fetch(:flow_type), steps: steps)
      end

      sig { params(clearing: T::Hash[ClearingKey, Integer], row: T::Hash[Symbol, T.untyped]).void }
      def self.accumulate(clearing, row)
        return unless row.fetch(:kind) == 'clearing'

        key = [row.fetch(:code), row.fetch(:currency)]
        amount = Integer(row.fetch(:amount))
        clearing[key] = clearing.fetch(key, 0) + (row.fetch(:side) == row.fetch(:normal_side) ? amount : -amount)
      end
      private_class_method :accumulate

      sig { params(rows: T::Array[T::Hash[Symbol, T.untyped]], clearing: T::Hash[ClearingKey, Integer]).returns(Step) }
      def self.step(rows, clearing)
        first = rows.fetch(0)
        lines = rows.map do |row|
          Line.new(account: row.fetch(:code), kind: row.fetch(:kind).to_sym,
                   side: Entry.side_from_column(row.fetch(:side)),
                   amount: Money.of(Integer(row.fetch(:amount)), row.fetch(:currency)))
        end
        Step.new(transaction_id: Integer(first.fetch(:id)), description: first.fetch(:description),
                 effective_at: first.fetch(:effective_at), reverses_transaction_id: first[:reverses_transaction_id],
                 reversed_by: first[:reversed_by], lines: lines, clearing_after: clearing)
      end
      private_class_method :step
    end
  end
end
