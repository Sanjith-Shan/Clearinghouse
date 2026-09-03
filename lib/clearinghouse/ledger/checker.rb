# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    # Recomputes every account's balance from its entries and compares it with
    # account_balances. The two are written together in one transaction, so they
    # can only disagree through a bug in posting or someone editing
    # account_balances by hand, and either one is worth waking up for.
    module Checker
      extend T::Sig

      # One account whose stored balance is not the sum of its entries. `stored`
      # is nil when the balance row is missing altogether.
      class Drift < T::Struct
        extend T::Sig

        const :account_id, Integer
        const :code, String
        const :currency, String
        const :stored, T.nilable(Integer)
        const :computed, Integer

        # Stored minus computed, in minor units on the account's normal side.
        sig { returns(Integer) }
        def difference
          (stored || 0) - computed
        end

        sig { returns(String) }
        def to_s
          stored_text = stored.nil? ? 'no balance row' : Money.of(T.must(stored), currency).to_s
          "#{code} (#{currency}): stored #{stored_text}, entries say #{Money.of(computed, currency)}"
        end
      end

      # What one run found. `accounts_checked` separates an empty ledger from a clean one.
      class Report < T::Struct
        extend T::Sig

        const :accounts_checked, Integer
        const :drifts, T::Array[Drift]

        sig { returns(T::Boolean) }
        def clean?
          drifts.empty?
        end
      end

      # One query: sum entries per account, sign the sum on the account's normal
      # side, and keep the accounts where that differs from the stored row. The
      # count of accounts rides along on the first row so an empty ledger and a
      # clean ledger are told apart.
      QUERY = <<~SQL
        WITH sums AS (
          SELECT account_id, sum(CASE side WHEN 'D' THEN amount ELSE -amount END) AS debit_net
            FROM ledger_entries GROUP BY account_id
        ), recomputed AS (
          SELECT a.id, a.code, a.currency, b.balance AS stored,
                 CASE a.normal_side WHEN 'D' THEN 1 ELSE -1 END * coalesce(s.debit_net, 0) AS computed
            FROM ledger_accounts a
            LEFT JOIN account_balances b ON b.account_id = a.id
            LEFT JOIN sums s ON s.account_id = a.id
        ), total AS (SELECT count(*) AS accounts_checked FROM recomputed)
        SELECT total.accounts_checked, r.*
          FROM total
          LEFT JOIN recomputed r ON r.stored IS DISTINCT FROM r.computed
         ORDER BY r.id
      SQL

      sig { params(db: Sequel::Database).returns(Report) }
      def self.run(db)
        rows = db.fetch(QUERY).all
        drifts = rows.reject { |row| row[:id].nil? }.map do |row|
          Drift.new(account_id: Integer(row.fetch(:id)), code: row.fetch(:code), currency: row.fetch(:currency),
                    stored: row[:stored]&.then { |v| Integer(v) }, computed: Integer(row.fetch(:computed)))
        end
        Report.new(accounts_checked: Integer(rows.fetch(0).fetch(:accounts_checked)), drifts: drifts)
      end
    end
  end
end
