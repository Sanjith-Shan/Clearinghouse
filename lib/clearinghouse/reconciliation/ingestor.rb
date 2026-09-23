# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Reconciliation
    # Fetches a day's settlement file, stores it, and reconciles every line in one
    # database transaction. Each line ends in one of these outcomes:
    #
    # | outcome     | posted? | exception           |
    # |-------------|---------|---------------------|
    # | `cleared`   | yes     | none                |
    # | `late`      | yes     | `late` (recorded, resolved on arrival) |
    # | `mismatch`  | yes*    | `amount_mismatch` or `fee_mismatch`    |
    # | `duplicate` | no      | `duplicate`         |
    # | `unknown`   | no      | `unknown_payment`   |
    # | `pending`   | no      | none yet: matched again on the next run |
    #
    # (*) A mismatched line books the cash that really moved; the difference from what
    # our ledger expected stays in the flow's clearing account, where it keeps the flow
    # unexplained until an operator resolves the exception.
    #
    # Ingesting a date twice changes nothing: the file row is unique by date and a
    # second fetch must hash the same.
    class Ingestor
      extend T::Sig

      # What one run did.
      class Result < T::Struct
        extend T::Sig

        const :date, Date
        # ingested | already_ingested | unavailable
        const :status, String
        const :outcomes, T::Hash[String, Integer], default: {}
        const :exceptions, T::Hash[String, Integer], default: {}
        # Lines from earlier files that were pending and matched in this run.
        const :pending_matched, Integer, default: 0
        const :detail, T.nilable(String)

        sig { returns(Integer) }
        def lines
          outcomes.values.sum
        end
      end

      # Every account a settlement line, or the reversal of a written-off one, posts
      # to. All platform accounts, each shared with the online paths: captures post
      # to the receivable, refunds and disputes to their clearing accounts.
      SETTLEMENT_ACCOUNTS = T.let([Ledger::Flows::CASH, Ledger::Flows::PROCESSING_EXPENSE, Ledger::Flows::RECEIVABLE,
                                   Ledger::Flows::REFUND_CLEARING, Ledger::Flows::DISPUTE_CLEARING].freeze,
                                  T::Array[String])

      LATE_EVIDENCE = <<~SQL
        SELECT settled_on FROM settlement_files
         WHERE settled_on < ? AND settled_on >= ? AND requested_at >= ? AND fetched_at > ?
         ORDER BY settled_on LIMIT 1
      SQL

      sig do
        params(db: Sequel::Database, client: Acquirer::Client, clock: Clock, config: Config).void
      end
      def initialize(db:, client:, clock:, config: Config.new)
        @db = db
        @client = client
        @clock = clock
        @config = config
        @matcher = T.let(Matcher.new(db, config: config), Matcher)
      end

      # Fetches and reconciles the file for `date`. `inject` asks the simulator for
      # discrepancies and is for tests and experiments only.
      sig { params(date: Date, inject: T::Array[T::Hash[String, T.untyped]]).returns(Result) }
      def ingest(date, inject: [])
        # Taken before the request: every posting created before this instant was
        # already at the acquirer when it built the file. See #late_evidence.
        fetched_at = T.cast(@db.get(Sequel.function(:clock_timestamp)), Time)
        requested_at = @clock.now
        csv = @client.settlement_file(date: date, inject: inject)
        return Result.new(date: date, status: 'unavailable', detail: csv.reason) if csv.is_a?(Acquirer::Unavailable)

        ingest_csv(date: date, csv: csv, requested_at: requested_at, fetched_at: fetched_at)
      end

      sig { params(date: Date, csv: String, requested_at: Time, fetched_at: Time).returns(Result) }
      def ingest_csv(date:, csv:, requested_at:, fetched_at:)
        sha = Digest::SHA256.hexdigest(csv)
        lines = SettlementCsv.parse(csv, date: date)
        T.let(@db.transaction do
          Reconciliation.lock!(@db)
          existing = @db[:settlement_files].where(settled_on: date).get(:sha256)
          if existing
            if existing != sha
              raise FileChangedError, "the #{date} file was ingested with sha256 #{existing}, now #{sha}"
            end

            next Result.new(date: date, status: 'already_ingested')
          end

          file_id = @db[:settlement_files].insert(settled_on: date, sha256: sha, raw: csv, line_count: lines.length,
                                                  requested_at: requested_at, fetched_at: fetched_at,
                                                  ingested_at: @clock.now)
          lock_settlement_balances
          lines.each { |line| reconcile(file_id, line) }
          matched = match_pending(before_file: file_id)
          summary(date, file_id, matched)
        end, Result)
      end

      # Tries every pending line again. Returns how many found their flow. Ingestion
      # does this after each file; call it after the poller catches up, too.
      sig { params(before_file: T.nilable(Integer)).returns(Integer) }
      def match_pending(before_file: nil)
        @db.transaction do
          Reconciliation.lock!(@db)
          lock_settlement_balances
          scope = @db[:settlement_lines].where(outcome: 'pending').order(:id)
          scope = scope.where(Sequel.lit('file_id < ?', before_file)) if before_file
          scope.all.count do |row|
            line = line_from(row)
            match = @matcher.match(line)
            next false if match.is_a?(Matcher::Unmatched) && match.pending

            match.is_a?(Matcher::Target) ? settle(line, match, row.fetch(:id)) : unknown(line, match, row.fetch(:id))
            true
          end
        end
      end

      private

      # One run posts once per line, all in one transaction, and each posting only
      # sorts its own accounts. So the run locks every settlement balance up front,
      # in account id order, as every other writer takes them. Otherwise a run that
      # had booked a dispute line (dispute_clearing) and then wanted refund_clearing
      # could close a cycle with a refund and a dispute win of one merchant
      # (docs/bugs/payouts-sweep-lock-order-deadlock.md). Only accounts that exist
      # are locked, so a run creates nothing it does not post to. A line's clearing
      # account always exists (the flow it matched posted to it); cash and
      # processing_expense are missing only before the first file or payout.
      sig { void }
      def lock_settlement_balances
        existing = @db[:ledger_accounts].where(code: SETTLEMENT_ACCOUNTS).select_map(%i[code currency])
        Ledger.lock_balances!(@db, existing.map { |code, currency| [String(code), String(currency)] })
      end

      sig { params(file_id: Integer, line: SettlementCsv::Line).void }
      def reconcile(file_id, line)
        original = @db[:settlement_lines].where(acquirer_reference: line.acquirer_reference, type: line.type,
                                                operation_id: line.operation_id)
                                         .exclude(outcome: 'duplicate').order(:id).first
        return duplicate(file_id, line, original) if original

        row_id = insert_line(file_id, line)
        match = @matcher.match(line)
        if match.is_a?(Matcher::Target)
          settle(line, match, row_id)
        elsif !match.pending
          unknown(line, match, row_id)
        end
      end

      sig { params(date: Date, file_id: Integer, matched: Integer).returns(Result) }
      def summary(date, file_id, matched)
        lines = @db[:settlement_lines].where(file_id: file_id)
        outcomes = lines.group_and_count(:outcome).to_h { |row| [row.fetch(:outcome), row.fetch(:count)] }
        exceptions = @db[:reconciliation_exceptions].where(settlement_line_id: lines.select(:id))
                                                    .group_and_count(:reason)
                                                    .to_h { |row| [row.fetch(:reason), row.fetch(:count)] }
        Result.new(date: date, status: 'ingested', outcomes: outcomes, exceptions: exceptions,
                   pending_matched: matched)
      end

      # Same movement as a line we already have (by the acquirer's reference, line
      # type and operation id; two refunds of one payment differ by operation id).
      # Never booked twice, whatever its amount says.
      sig { params(file_id: Integer, line: SettlementCsv::Line, original: T::Hash[Symbol, T.untyped]).void }
      def duplicate(file_id, line, original)
        row_id = insert_line(file_id, line, outcome: 'duplicate', flow_id: original[:flow_id])
        first_seen = @db[:settlement_files].where(id: original.fetch(:file_id)).get(:settled_on)
        raise_exception(line, row_id, 'duplicate',
                        "same movement as line #{original.fetch(:line_id)} in the #{first_seen} file; not booked again",
                        flow_id: original[:flow_id])
      end

      sig { params(line: SettlementCsv::Line, match: Matcher::Unmatched, row_id: Integer).void }
      def unknown(line, match, row_id)
        update_line(row_id, outcome: 'unknown')
        raise_exception(line, row_id, 'unknown_payment', match.detail)
      end

      sig { params(line: SettlementCsv::Line, target: Matcher::Target, row_id: Integer).void }
      def settle(line, target, row_id)
        problems = discrepancies(line, target)
        mismatched = problems.any? { |reason, _| reason != 'late' }
        entries = mismatched ? discrepancy_entries(line, target) : exact_entries(line)
        txn = post(line, target, entries)
        outcome = if mismatched then 'mismatch'
                  elsif problems.empty? then 'cleared'
                  else 'late'
                  end
        update_line(row_id, outcome: outcome, flow_id: target.flow_id, ledger_transaction_id: txn)
        missing_arrived(line, target)
        problems.each do |reason, detail|
          late = reason == 'late'
          stuck = late ? 0 : unexplained(line, target, posted: !txn.nil?)
          id = raise_exception(line, row_id, reason, detail, target: target, unexplained: stuck)
          Exceptions.close_automatically!(@db, id, note: 'cleared on arrival; nothing to do', now: @clock.now) if late
        end
      end

      # The SLA job may already have called this line missing. It was not: it was
      # late. An open `missing` exception closes itself. One an operator already
      # wrote off gets its write-off reversed, because the money did arrive and the
      # line has just been booked; leaving both would count it twice.
      sig { params(line: SettlementCsv::Line, target: Matcher::Target).void }
      def missing_arrived(line, target)
        row = @db[:reconciliation_exceptions].where(reason: 'missing', flow_id: target.flow_id, line_type: line.type)
                                             .first
        return unless row

        note = "the line arrived in the #{line.settled_on} file and was booked"
        return Exceptions.close_automatically!(@db, row.fetch(:id), note: note, now: @clock.now) if
          row.fetch(:status) == 'open'

        write_off = row[:resolution_transaction_id]
        return unless row[:resolution_action] == 'write_off' && write_off

        reversal = begin
          Ledger.reverse!(@db, write_off, reason: "#{row.fetch(:id)}: #{note}", effective_at: @clock.now)
        rescue Ledger::AlreadyReversedError
          nil # an operator already undid it
        end
        after = reversal ? "transaction #{reversal} reverses the write-off" : 'the write-off was already reversed'
        @db[:reconciliation_exceptions].where(id: row.fetch(:id))
                                       .update(resolution_note: "#{row[:resolution_note]} Later #{note}; #{after}.")
      end

      # What is wrong with the line: at most one of amount (or currency) and fee, the
      # amount checked first because a wrong amount usually makes the fee look wrong
      # too; and, independently, whether it is late. A late line can also be wrong,
      # and both are reported.
      sig { params(line: SettlementCsv::Line, target: Matcher::Target).returns(T::Array[[String, String]]) }
      def discrepancies(line, target)
        problems = T.let([], T::Array[[String, String]])
        if line.currency != target.currency
          problems << ['amount_mismatch', "line is in #{line.currency}, #{target.flow_id} is in #{target.currency}"]
        elsif line.amount != target.expected_amount
          problems << ['amount_mismatch',
                       "line says #{line.amount}, #{target.flow_id} expects #{target.expected_amount}"]
        elsif line.fee != target.expected_fee
          problems << ['fee_mismatch', "line takes a fee of #{line.fee}, the fee schedule gives #{target.expected_fee}"]
        end
        evidence = late_evidence(line, target)
        if evidence
          due = @config.due_on(target.happened_at)
          problems << ['late', "due on #{due} and missing from the #{evidence} file, which already knew about it; " \
                               "arrived #{(line.settled_on - due).to_i} days after its due date"]
        end
        problems
      end

      # A line is late only if an earlier file we ingested should have held it: its
      # date was on or after the line's due date, it was generated at a simulated
      # time after the movement, and it was fetched after we recorded the movement
      # (so the acquirer had it). A line that happened after the file for its due
      # date was built (a caller with a lagging clock) is carried into the next file
      # by the acquirer, and that is not late.
      sig { params(line: SettlementCsv::Line, target: Matcher::Target).returns(T.nilable(Date)) }
      def late_evidence(line, target)
        @db.fetch(LATE_EVIDENCE, line.settled_on, @config.due_on(target.happened_at), target.happened_at,
                  target.recorded_at).get(:settled_on)
      end

      sig { params(line: SettlementCsv::Line).returns(T::Array[Ledger::Entry]) }
      def exact_entries(line)
        flows = Ledger::Flows
        amount = Money.of(line.amount.abs, line.currency)
        case line.type
        when 'capture' then flows.settlement(gross: amount, acquirer_fee: Money.of(line.fee, line.currency))
        when 'refund' then flows.refund_settled(amount: amount)
        when 'dispute' then flows.dispute_debited(amount: amount)
        else flows.dispute_funds_returned(amount: amount)
        end
      end

      # Books the cash that really moved (amount minus fee) and the fee our contract
      # allows, and lets the flow's clearing account take the rest. For a line that
      # matches, this is exactly the entries above; for one that does not, the
      # difference stays in clearing, where the data-quality report will see it.
      sig { params(line: SettlementCsv::Line, target: Matcher::Target).returns(T::Array[Ledger::Entry]) }
      def discrepancy_entries(line, target)
        return [] if line.currency != target.currency

        currency = line.currency
        cash = line.amount - line.fee
        entries = []
        entries << Ledger::Entry.debit(Ledger::Flows::CASH, Money.of(cash, currency)) if cash.positive?
        entries << Ledger::Entry.credit(Ledger::Flows::CASH, Money.of(-cash, currency)) if cash.negative?
        if target.expected_fee.positive?
          entries << Ledger::Entry.debit(Ledger::Flows::PROCESSING_EXPENSE, Money.of(target.expected_fee, currency))
        end
        net = cash + target.expected_fee
        entries << Ledger::Entry.credit(target.clearing_account, Money.of(net, currency)) if net.positive?
        entries << Ledger::Entry.debit(target.clearing_account, Money.of(-net, currency)) if net.negative?
        entries
      end

      # What this line leaves in the flow's clearing account, signed on that account's
      # normal side. The clearing account takes `net` (credited when positive); a line
      # that matched would have had net == expected_amount.
      sig { params(line: SettlementCsv::Line, target: Matcher::Target, posted: T::Boolean).returns(Integer) }
      def unexplained(line, target, posted:)
        net = posted ? line.amount - line.fee + target.expected_fee : 0
        normal_credit = Ledger::AccountCode.parse(target.clearing_account).normal_side == :credit
        (normal_credit ? 1 : -1) * (net - target.expected_amount)
      end

      sig do
        params(line: SettlementCsv::Line, target: Matcher::Target, entries: T::Array[Ledger::Entry])
          .returns(T.nilable(Integer))
      end
      def post(line, target, entries)
        return nil if entries.length < 2

        Ledger.post!(@db, flow_type: target.flow_type, flow_id: target.flow_id, description: description(line, target),
                          effective_at: Time.utc(line.settled_on.year, line.settled_on.month, line.settled_on.day),
                          entries: entries)
      end

      # Names the payment, the convention bin/explain links flows by.
      sig { params(line: SettlementCsv::Line, target: Matcher::Target).returns(String) }
      def description(line, target)
        what = case line.type
               when 'capture' then "settlement of #{target.flow_id}"
               when 'refund' then "settlement of refund #{target.flow_id} of #{target.payment_intent}"
               when 'dispute' then "acquirer debit for dispute #{target.flow_id} on #{target.payment_intent}"
               else "acquirer return for dispute #{target.flow_id} on #{target.payment_intent}"
               end
        "#{what} (line #{line.line_id}, #{line.settled_on})"
      end

      sig do
        params(line: SettlementCsv::Line, row_id: Integer, reason: String, detail: String,
               target: T.nilable(Matcher::Target), unexplained: Integer, flow_id: T.nilable(String)).returns(String)
      end
      def raise_exception(line, row_id, reason, detail, target: nil, unexplained: 0, flow_id: nil)
        draft = Exceptions::Draft.new(
          reason: reason, line_type: line.type, currency: line.currency, detail: detail, settlement_line_id: row_id,
          flow_id: target&.flow_id || flow_id, flow_type: target&.flow_type, merchant_id: target&.merchant_id,
          acquirer_reference: line.acquirer_reference, operation_id: line.operation_id,
          expected_amount: target&.expected_amount, expected_fee: target&.expected_fee,
          clearing_account: target&.clearing_account, unexplained_amount: unexplained
        )
        Exceptions.create!(@db, draft, now: @clock.now)
      end

      sig do
        params(file_id: Integer, line: SettlementCsv::Line, outcome: String, flow_id: T.nilable(String))
          .returns(Integer)
      end
      def insert_line(file_id, line, outcome: 'pending', flow_id: nil)
        @db[:settlement_lines].insert(
          file_id: file_id, position: line.position, line_id: line.line_id, type: line.type,
          acquirer_reference: line.acquirer_reference, operation_id: line.operation_id, amount: line.amount,
          fee: line.fee, currency: line.currency, settled_on: line.settled_on, outcome: outcome, flow_id: flow_id
        )
      end

      sig do
        params(row_id: Integer, outcome: String, flow_id: T.nilable(String),
               ledger_transaction_id: T.nilable(Integer)).void
      end
      def update_line(row_id, outcome:, flow_id: nil, ledger_transaction_id: nil)
        @db[:settlement_lines].where(id: row_id)
                              .update(outcome: outcome, flow_id: flow_id, ledger_transaction_id: ledger_transaction_id)
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(SettlementCsv::Line) }
      def line_from(row)
        SettlementCsv::Line.new(position: row.fetch(:position), line_id: row.fetch(:line_id), type: row.fetch(:type),
                                acquirer_reference: row.fetch(:acquirer_reference),
                                operation_id: row.fetch(:operation_id), amount: row.fetch(:amount),
                                fee: row.fetch(:fee), currency: row.fetch(:currency),
                                settled_on: row.fetch(:settled_on))
      end
    end
  end
end
