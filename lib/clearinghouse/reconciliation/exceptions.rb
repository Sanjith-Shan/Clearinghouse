# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Reconciliation
    # A settlement line (or an expected line that never came) the reconciler could not
    # simply clear. `reason` is one of REASONS; `unexplained_amount` is what it leaves
    # stuck in `clearing_account` for its flow, signed on that account's normal side.
    class ReconciliationException < T::Struct
      extend T::Sig

      const :id, String
      const :reason, String
      const :status, String
      const :flow_id, T.nilable(String)
      const :flow_type, T.nilable(String)
      const :merchant_id, T.nilable(String)
      const :line_type, String
      const :acquirer_reference, T.nilable(String)
      const :operation_id, T.nilable(String)
      const :currency, String
      const :expected_amount, T.nilable(Integer)
      const :expected_fee, T.nilable(Integer)
      const :clearing_account, T.nilable(String)
      const :unexplained_amount, Integer
      const :detail, String
      const :created_at, Time
      # The line as the acquirer sent it, when there was one.
      const :settlement_line, T.nilable(T::Hash[String, T.untyped])
      const :resolved_at, T.nilable(Time)
      const :resolution_action, T.nilable(String)
      const :resolution_note, T.nilable(String)
      const :resolution_transaction_id, T.nilable(Integer)

      sig { returns(T::Boolean) }
      def open?
        status == 'open'
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_api
        {
          'id' => id, 'object' => 'reconciliation_exception', 'reason' => reason, 'status' => status,
          'flow' => flow_id, 'flow_type' => flow_type, 'merchant' => merchant_id, 'line_type' => line_type,
          'acquirer_reference' => acquirer_reference, 'operation_id' => operation_id, 'currency' => currency,
          'expected' => expected_amount.nil? ? nil : { 'amount' => expected_amount, 'fee' => expected_fee },
          'settlement_line' => settlement_line, 'clearing_account' => clearing_account,
          'unexplained_amount' => unexplained_amount, 'detail' => detail, 'created' => created_at.to_i,
          'resolution' => resolution_api
        }
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(ReconciliationException) }
      def self.from_row(row)
        new(id: row.fetch(:id), reason: row.fetch(:reason), status: row.fetch(:status), flow_id: row[:flow_id],
            flow_type: row[:flow_type], merchant_id: row[:merchant_id], line_type: row.fetch(:line_type),
            acquirer_reference: row[:acquirer_reference], operation_id: row[:operation_id],
            currency: row.fetch(:currency), expected_amount: row[:expected_amount], expected_fee: row[:expected_fee],
            clearing_account: row[:clearing_account], unexplained_amount: Integer(row.fetch(:unexplained_amount)),
            detail: row.fetch(:detail), created_at: row.fetch(:created_at).utc, settlement_line: line_api(row),
            resolved_at: row[:resolved_at]&.utc, resolution_action: row[:resolution_action],
            resolution_note: row[:resolution_note], resolution_transaction_id: row[:resolution_transaction_id])
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(T.nilable(T::Hash[String, T.untyped])) }
      def self.line_api(row)
        return nil if row[:line_line_id].nil?

        { 'line_id' => row[:line_line_id], 'settled_on' => row.fetch(:line_settled_on).iso8601,
          'amount' => row.fetch(:line_amount), 'fee' => row.fetch(:line_fee) }
      end

      private

      sig { returns(T.nilable(T::Hash[String, T.untyped])) }
      def resolution_api
        return nil if open?

        { 'action' => resolution_action, 'note' => resolution_note, 'ledger_transaction' => resolution_transaction_id,
          'resolved' => resolved_at&.to_i }
      end
    end

    # The exceptions table, and resolving an exception.
    module Exceptions
      extend T::Sig

      ACTIONS = %w[none write_off reverse].freeze

      class NotFoundError < Error; end
      class AlreadyResolvedError < Error; end
      # The resolution asked for cannot apply to this exception.
      class InvalidResolutionError < Error; end

      # The fields a new exception is made of; the rest have defaults.
      class Draft < T::Struct
        const :reason, String
        const :line_type, String
        const :currency, String
        const :detail, String
        const :settlement_line_id, T.nilable(Integer)
        const :flow_id, T.nilable(String)
        const :flow_type, T.nilable(String)
        const :merchant_id, T.nilable(String)
        const :acquirer_reference, T.nilable(String)
        const :operation_id, T.nilable(String)
        const :expected_amount, T.nilable(Integer)
        const :expected_fee, T.nilable(Integer)
        const :clearing_account, T.nilable(String)
        const :unexplained_amount, Integer, default: 0
      end

      sig { params(db: Sequel::Database, draft: Draft, now: Time).returns(String) }
      def self.create!(db, draft, now:)
        raise ArgumentError, "unknown reason #{draft.reason}" unless REASONS.include?(draft.reason)

        id = Ids.generate('rex')
        db[:reconciliation_exceptions].insert(draft.serialize.transform_keys(&:to_sym)
                                                   .merge(id: id, status: 'open', created_at: now))
        id
      end

      # Resolved at creation, for exceptions that record something without needing
      # anyone to act (a late line that cleared on arrival).
      sig { params(db: Sequel::Database, id: String, note: String, now: Time).void }
      def self.close_automatically!(db, id, note:, now:)
        db[:reconciliation_exceptions].where(id: id, status: 'open')
                                      .update(status: 'resolved', resolved_at: now, resolution_action: 'auto',
                                              resolution_note: note)
      end

      sig { params(db: Sequel::Database, id: String, lock: T::Boolean).returns(T.nilable(ReconciliationException)) }
      def self.find(db, id, lock: false)
        # Lock the exception's own row, not the joined line.
        db[:reconciliation_exceptions].where(id: id).for_update.get(:id) if lock
        row = with_lines(db).where(Sequel[:reconciliation_exceptions][:id] => id).first
        row ? ReconciliationException.from_row(row) : nil
      end

      # Oldest first, the order an operator works through them.
      sig do
        params(db: Sequel::Database, limit: Integer, status: T.nilable(String), reason: T.nilable(String),
               flow_id: T.nilable(String), starting_after: T.nilable(String))
          .returns([T::Array[ReconciliationException], T::Boolean])
      end
      def self.list(db, limit:, status: nil, reason: nil, flow_id: nil, starting_after: nil)
        table = Sequel[:reconciliation_exceptions]
        scope = with_lines(db)
        scope = scope.where(table[:status] => status) if status
        scope = scope.where(table[:reason] => reason) if reason
        scope = scope.where(table[:flow_id] => flow_id) if flow_id
        if starting_after
          cursor = db[:reconciliation_exceptions].where(id: starting_after).first
          raise NotFoundError, "no reconciliation exception #{starting_after}" unless cursor

          after = '(reconciliation_exceptions.created_at, reconciliation_exceptions.id) > (?, ?)'
          scope = scope.where(Sequel.lit(after, cursor.fetch(:created_at), cursor.fetch(:id)))
        end
        rows = scope.order(table[:created_at], table[:id]).limit(limit + 1).all
        [rows.first(limit).map { |row| ReconciliationException.from_row(row) }, rows.length > limit]
      end

      # Closes an exception with an operator's note, and optionally a correcting
      # posting in its flow:
      #
      # - `none`: nothing to post (a duplicate line we never booked, an unknown payment
      #   handed to another team).
      # - `write_off`: posts the unexplained amount out of the clearing account against
      #   processing_expense, so the flow is explained again. For a short payment by
      #   the acquirer that is a loss; for an overpayment, a gain.
      # - `reverse`: reverses one ledger transaction of the exception's flow (a wrong
      #   settlement posting, a write-off made in error).
      sig do
        params(db: Sequel::Database, id: String, action: String, note: String, clock: Clock,
               ledger_transaction: T.nilable(Integer)).returns(ReconciliationException)
      end
      def self.resolve!(db, id, action:, note:, clock:, ledger_transaction: nil)
        raise InvalidResolutionError, "action must be one of #{ACTIONS.join(', ')}" unless ACTIONS.include?(action)
        raise InvalidResolutionError, 'a resolution needs a note' if note.strip.empty?

        db.transaction do
          exception = find(db, id, lock: true)
          raise NotFoundError, "no reconciliation exception #{id}" unless exception
          raise AlreadyResolvedError, "#{id} was resolved at #{exception.resolved_at&.iso8601}" unless exception.open?

          txn = post_resolution(db, exception, action: action, note: note, clock: clock,
                                               ledger_transaction: ledger_transaction)
          db[:reconciliation_exceptions].where(id: id).update(
            status: 'resolved', resolved_at: clock.now, resolution_action: action, resolution_note: note,
            resolution_transaction_id: txn
          )
          T.must(find(db, id))
        end
      end

      sig do
        params(db: Sequel::Database, exception: ReconciliationException, action: String, note: String, clock: Clock,
               ledger_transaction: T.nilable(Integer)).returns(T.nilable(Integer))
      end
      def self.post_resolution(db, exception, action:, note:, clock:, ledger_transaction:)
        if ledger_transaction && action != 'reverse'
          raise InvalidResolutionError,
                'ledger_transaction is only for reverse'
        end

        case action
        when 'write_off' then write_off(db, exception, clock)
        when 'reverse' then reverse(db, exception, T.must(ledger_transaction || missing_transaction!), note, clock)
        end
      end
      private_class_method :post_resolution

      sig { returns(T.noreturn) }
      def self.missing_transaction!
        raise InvalidResolutionError, 'reverse needs ledger_transaction'
      end
      private_class_method :missing_transaction!

      sig { params(db: Sequel::Database, exception: ReconciliationException, clock: Clock).returns(Integer) }
      def self.write_off(db, exception, clock)
        stuck = exception.unexplained_amount
        account = exception.clearing_account
        raise InvalidResolutionError, "#{exception.id} leaves nothing stuck to write off" if stuck.zero? || account.nil?

        amount = Money.of(stuck.abs, exception.currency)
        # Move the stuck amount back toward zero on its own account; the other side is
        # the platform's processing expense (a loss when positive, a gain when negative).
        reduce_with_credit = (stuck.positive? == (Ledger::AccountCode.parse(account).normal_side == :debit))
        entries = if reduce_with_credit
                    [Ledger::Entry.credit(account, amount),
                     Ledger::Entry.debit(Ledger::Flows::PROCESSING_EXPENSE, amount)]
                  else
                    [Ledger::Entry.debit(account, amount),
                     Ledger::Entry.credit(Ledger::Flows::PROCESSING_EXPENSE, amount)]
                  end
        Ledger.post!(db, flow_type: T.must(exception.flow_type), flow_id: T.must(exception.flow_id),
                         description: "write-off of #{exception.reason} #{exception.id} on #{exception.flow_id}",
                         effective_at: clock.now, entries: entries)
      end
      private_class_method :write_off

      sig do
        params(db: Sequel::Database, exception: ReconciliationException, transaction_id: Integer, note: String,
               clock: Clock).returns(Integer)
      end
      def self.reverse(db, exception, transaction_id, note, clock)
        flow = db[:ledger_transactions].where(id: transaction_id).get(:flow_id)
        unless flow && flow == exception.flow_id
          raise InvalidResolutionError, "transaction #{transaction_id} is not in #{exception.id}'s flow"
        end

        Ledger.reverse!(db, transaction_id, reason: "#{exception.id}: #{note}", effective_at: clock.now)
      rescue Ledger::AlreadyReversedError, Ledger::NotReversibleError => e
        raise InvalidResolutionError, e.message
      end
      private_class_method :reverse

      sig { params(db: Sequel::Database).returns(Sequel::Dataset) }
      def self.with_lines(db)
        lines = Sequel[:settlement_lines]
        db[:reconciliation_exceptions]
          .left_join(:settlement_lines, id: :settlement_line_id)
          .select_all(:reconciliation_exceptions)
          .select_append(lines[:line_id].as(:line_line_id), lines[:settled_on].as(:line_settled_on),
                         lines[:amount].as(:line_amount), lines[:fee].as(:line_fee))
      end
      private_class_method :with_lines
    end
  end
end
