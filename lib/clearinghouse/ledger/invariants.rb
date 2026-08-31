# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    # The global properties any sequence of ledger operations must preserve. Built
    # for model-based tests, which call `check!` after every step, and cheap
    # enough to run as a periodic job.
    #
    # 1. zero_sum: in each currency, debits minus credits over every entry is zero.
    #    Money is never created or destroyed, only moved.
    # 2. balanced_transactions: every transaction has at least two entries and
    #    balances in each of its currencies.
    # 3. balances_match_entries: account_balances equals the sum of entries
    #    (Checker).
    #
    # The database already refuses writes that break 1 and 2, so a violation here
    # means that protection was bypassed. The check exists so that claim is tested
    # rather than assumed.
    module Invariants
      extend T::Sig

      # Which invariant failed, and a line a human can act on.
      class Violation < T::Struct
        const :invariant, Symbol
        const :detail, String
      end

      # Raised by check! with every violation found, not just the first.
      class ViolationError < Ledger::Error
        extend T::Sig

        sig { returns(T::Array[Violation]) }
        attr_reader :violations

        sig { params(violations: T::Array[Violation]).void }
        def initialize(violations)
          @violations = violations
          super("ledger invariants violated:\n#{violations.map { |v| "  #{v.invariant}: #{v.detail}" }.join("\n")}")
        end
      end

      SIGNED = "CASE side WHEN 'D' THEN amount ELSE -amount END"

      sig { params(db: Sequel::Database).returns(T::Array[Violation]) }
      def self.check(db)
        zero_sum(db) + balanced_transactions(db) + balances_match_entries(db)
      end

      sig { params(db: Sequel::Database).void }
      def self.check!(db)
        violations = check(db)
        raise ViolationError, violations unless violations.empty?
      end

      sig { params(db: Sequel::Database).returns(T::Array[Violation]) }
      def self.zero_sum(db)
        db.fetch("SELECT currency, sum(#{SIGNED}) AS net FROM ledger_entries GROUP BY currency " \
                 "HAVING sum(#{SIGNED}) <> 0 ORDER BY currency").map do |row|
          currency = row.fetch(:currency)
          Violation.new(invariant: :zero_sum,
                        detail: "#{currency} debits minus credits is #{Money.of(Integer(row.fetch(:net)), currency)}")
        end
      end

      sig { params(db: Sequel::Database).returns(T::Array[Violation]) }
      def self.balanced_transactions(db)
        short = db.fetch(<<~SQL).map { |r| "transaction #{r.fetch(:id)} has #{r.fetch(:n)} entries" }
          SELECT t.id, count(e.id) AS n FROM ledger_transactions t
            LEFT JOIN ledger_entries e ON e.transaction_id = t.id
           GROUP BY t.id HAVING count(e.id) < 2 ORDER BY t.id
        SQL
        unbalanced = db.fetch(<<~SQL).map do |r|
          SELECT transaction_id, currency, sum(#{SIGNED}) AS net FROM ledger_entries
           GROUP BY transaction_id, currency HAVING sum(#{SIGNED}) <> 0 ORDER BY transaction_id, currency
        SQL
          "transaction #{r.fetch(:transaction_id)} is off by #{Money.of(Integer(r.fetch(:net)), r.fetch(:currency))}"
        end
        (short + unbalanced).map { |detail| Violation.new(invariant: :balanced_transactions, detail: detail) }
      end

      sig { params(db: Sequel::Database).returns(T::Array[Violation]) }
      def self.balances_match_entries(db)
        Checker.run(db).drifts.map { |d| Violation.new(invariant: :balances_match_entries, detail: d.to_s) }
      end
    end
  end
end
