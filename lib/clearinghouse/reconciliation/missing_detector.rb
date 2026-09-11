# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Reconciliation
    # Finds expected settlement lines that never came. A missing line is not in any
    # file, so no line can report it: it is found from our side, by listing every
    # movement our ledger expects the acquirer to settle and checking that a line for
    # it has arrived by its due date plus the slack.
    #
    # "By its due date" is measured in files ingested, not wall time: a movement due
    # on D is missing once we have ingested a file dated D + slack_days and seen no
    # line for it. A day we never fetched cannot make anything look missing.
    #
    # Each expected line gets at most one `missing` exception (a unique index), so the
    # job can run as often as it likes. It takes the reconciliation lock, so it never
    # sees a file half-ingested.
    class MissingDetector
      extend T::Sig

      # One line we expect and have not seen.
      class Expectation < T::Struct
        const :flow_id, String
        const :flow_type, String
        const :line_type, String
        const :merchant_id, T.nilable(String)
        const :acquirer_reference, T.nilable(String)
        const :operation_id, T.nilable(String)
        const :happened_at, Time
        const :amount, Integer # positive, in minor units
        const :currency, String
      end

      # Payments expect a capture line, refunds a refund line: both from the flow's
      # first transaction, which moved the amount into clearing.
      PAYMENTS_AND_REFUNDS = <<~SQL
        WITH firsts AS (
          SELECT DISTINCT ON (flow_id) flow_id, flow_type, id AS txn_id, effective_at
            FROM ledger_transactions
           WHERE flow_type IN ('payment', 'refund')
           ORDER BY flow_id, effective_at, id
        )
        SELECT f.flow_id, f.flow_type, f.effective_at,
               CASE f.flow_type WHEN 'payment' THEN 'capture' ELSE 'refund' END AS line_type,
               e.amount, e.currency,
               (SELECT a2.owner_id FROM ledger_entries e2 JOIN ledger_accounts a2 ON a2.id = e2.account_id
                 WHERE e2.transaction_id = f.txn_id AND a2.owner_id IS NOT NULL LIMIT 1) AS merchant_id,
               coalesce(pi.acquirer_reference, rpi.acquirer_reference) AS acquirer_reference,
               r.acquirer_operation_id AS operation_id
          FROM firsts f
          JOIN ledger_entries e ON e.transaction_id = f.txn_id
          JOIN ledger_accounts a ON a.id = e.account_id AND a.kind = 'clearing'
          LEFT JOIN payment_intents pi ON pi.id = f.flow_id
          LEFT JOIN refunds r ON r.id = f.flow_id
          LEFT JOIN payment_intents rpi ON rpi.id = r.payment_intent_id
         WHERE (f.effective_at AT TIME ZONE 'UTC')::date <= ?
      SQL

      # Disputes expect a `dispute` line from their opening and, once won, a
      # `dispute_reversal` line from the win.
      DISPUTES = <<~SQL
        SELECT d.id AS flow_id, 'dispute' AS flow_type, t.effective_at, x.line_type, d.amount, d.currency,
               d.merchant_id, d.acquirer_reference, d.acquirer_dispute_id AS operation_id
          FROM disputes d
          CROSS JOIN LATERAL (VALUES ('dispute', d.opened_transaction_id),
                                     ('dispute_reversal', d.won_transaction_id)) AS x (line_type, txn_id)
          JOIN ledger_transactions t ON t.id = x.txn_id
         WHERE (t.effective_at AT TIME ZONE 'UTC')::date <= ?
      SQL

      sig { params(db: Sequel::Database, clock: Clock, config: Config).void }
      def initialize(db:, clock:, config: Config.new)
        @db = db
        @clock = clock
        @config = config
      end

      # Raises a `missing` exception for each overdue line and returns their ids.
      sig { returns(T::Array[String]) }
      def run
        @db.transaction do
          Reconciliation.lock!(@db)
          overdue.map { |expectation| raise_missing(expectation) }
        end
      end

      # Expected lines that are overdue and not yet reported, oldest first.
      sig { returns(T::Array[Expectation]) }
      def overdue
        latest = @db[:settlement_files].max(:settled_on)
        return [] if latest.nil?

        # Happened on or before this date means due on or before latest - slack.
        cutoff = latest - @config.slack_days - @config.lag_days
        rows = @db.fetch(PAYMENTS_AND_REFUNDS, cutoff).all + @db.fetch(DISPUTES, cutoff).all
        seen = arrived_or_reported(rows.map { |row| row.fetch(:flow_id) })
        rows.reject { |row| seen.include?([row.fetch(:flow_id), row.fetch(:line_type)]) }
            .sort_by { |row| [row.fetch(:effective_at), row.fetch(:flow_id), row.fetch(:line_type)] }
            .map { |row| expectation(row) }
      end

      private

      # [flow_id, line_type] pairs that already have a line, or a missing exception.
      sig { params(flow_ids: T::Array[String]).returns(T::Set[[String, String]]) }
      def arrived_or_reported(flow_ids)
        return Set.new if flow_ids.empty?

        lines = @db[:settlement_lines].where(flow_id: flow_ids).select_map(%i[flow_id type])
        reported = @db[:reconciliation_exceptions].where(reason: 'missing', flow_id: flow_ids)
                                                  .select_map(%i[flow_id line_type])
        Set.new(lines + reported)
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(Expectation) }
      def expectation(row)
        Expectation.new(flow_id: row.fetch(:flow_id), flow_type: row.fetch(:flow_type),
                        line_type: row.fetch(:line_type), merchant_id: row[:merchant_id],
                        acquirer_reference: row[:acquirer_reference], operation_id: row[:operation_id],
                        happened_at: row.fetch(:effective_at).utc, amount: Integer(row.fetch(:amount)),
                        currency: row.fetch(:currency))
      end

      # The exception holds the whole expected amount as unexplained: nothing has
      # cleared it. A capture, refund or dispute line would have reduced its clearing
      # account by the amount; a reversal was owed to us, so its account is short.
      sig { params(expectation: Expectation).returns(String) }
      def raise_missing(expectation)
        line_type = expectation.line_type
        amount = expectation.amount
        signed = %w[capture dispute_reversal].include?(line_type) ? amount : -amount
        fee = line_type == 'capture' ? @config.expected_acquirer_fee(Money.of(amount, expectation.currency)).amount : 0
        due = @config.due_on(expectation.happened_at)
        draft = Exceptions::Draft.new(
          reason: 'missing', line_type: line_type, currency: expectation.currency,
          detail: "#{line_type} line due on #{due} (movement on #{expectation.happened_at.utc.to_date}) is in no " \
                  'settlement file ingested so far',
          flow_id: expectation.flow_id, flow_type: expectation.flow_type, merchant_id: expectation.merchant_id,
          acquirer_reference: expectation.acquirer_reference, operation_id: expectation.operation_id,
          expected_amount: signed, expected_fee: fee, clearing_account: clearing_account(line_type),
          unexplained_amount: line_type == 'dispute_reversal' ? -amount : amount
        )
        Exceptions.create!(@db, draft, now: @clock.now)
      end

      sig { params(line_type: String).returns(String) }
      def clearing_account(line_type)
        case line_type
        when 'capture' then Ledger::Flows::RECEIVABLE
        when 'refund' then Ledger::Flows::REFUND_CLEARING
        else Ledger::Flows::DISPUTE_CLEARING
        end
      end
    end
  end
end
