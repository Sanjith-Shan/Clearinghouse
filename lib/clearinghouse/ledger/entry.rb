# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    # One line of a ledger transaction: an account code, a side and a positive
    # amount. The account's currency is the amount's currency.
    class Entry < T::Struct
      extend T::Sig

      SIDES = %i[debit credit].freeze

      const :account, String
      const :side, Symbol
      const :amount, Money

      sig { params(account: String, amount: Money).returns(Entry) }
      def self.debit(account, amount)
        new(account: account, side: :debit, amount: amount)
      end

      sig { params(account: String, amount: Money).returns(Entry) }
      def self.credit(account, amount)
        new(account: account, side: :credit, amount: amount)
      end

      sig { params(column: String).returns(Symbol) }
      def self.side_from_column(column)
        column == 'D' ? :debit : :credit
      end

      sig { returns(String) }
      def side_column
        side == :debit ? 'D' : 'C'
      end

      # Debits positive, credits negative. Summed per currency over any set of
      # whole transactions this is always zero.
      sig { returns(Integer) }
      def signed_amount
        side == :debit ? amount.amount : -amount.amount
      end

      sig { returns(Entry) }
      def flipped
        Entry.new(account: account, side: side == :debit ? :credit : :debit, amount: amount)
      end
    end
  end
end
