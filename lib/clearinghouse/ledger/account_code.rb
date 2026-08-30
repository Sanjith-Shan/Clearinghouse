# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    # A parsed account code. The code alone decides an account's kind and normal
    # side, so accounts can be created on first use without a setup step and two
    # callers can never disagree about what `platform:cash` is.
    #
    #   platform:<name>                     one of PLATFORM
    #   merchant:<merchant_id>:<name>       one of MERCHANT
    class AccountCode < T::Struct
      extend T::Sig

      PLATFORM = T.let(
        {
          'cash' => %i[asset debit],
          'processor_receivable' => %i[clearing debit],
          'refund_clearing' => %i[clearing credit],
          'dispute_clearing' => %i[clearing credit],
          'payout_clearing' => %i[clearing credit],
          'fee_revenue' => %i[revenue credit],
          'dispute_fee_revenue' => %i[revenue credit],
          'processing_expense' => %i[expense debit],
          'dispute_losses' => %i[expense debit]
        }.freeze,
        T::Hash[String, [Symbol, Symbol]]
      )

      MERCHANT = T.let(
        {
          'pending' => %i[liability credit],
          'available' => %i[liability credit],
          'held' => %i[liability credit]
        }.freeze,
        T::Hash[String, [Symbol, Symbol]]
      )

      MERCHANT_ID = /\A[A-Za-z0-9_]{1,64}\z/

      const :code, String
      const :kind, Symbol
      const :normal_side, Symbol
      const :owner_id, T.nilable(String)

      sig { params(code: String).returns(AccountCode) }
      def self.parse(code)
        scope, *rest = code.split(':', -1)
        if scope == 'platform' && rest.length == 1
          build(code, PLATFORM[rest.fetch(0)], nil)
        elsif scope == 'merchant' && rest.length == 2 && MERCHANT_ID.match?(rest.fetch(0))
          build(code, MERCHANT[rest.fetch(1)], rest.fetch(0))
        else
          raise UnknownAccountError, "unknown ledger account code #{code.inspect}"
        end
      end

      sig { params(code: String, shape: T.nilable([Symbol, Symbol]), owner_id: T.nilable(String)).returns(AccountCode) }
      private_class_method def self.build(code, shape, owner_id)
        raise UnknownAccountError, "unknown ledger account code #{code.inspect}" unless shape

        new(code: code, kind: shape[0], normal_side: shape[1], owner_id: owner_id)
      end

      sig { params(name: String).returns(String) }
      def self.platform(name)
        parse("platform:#{name}").code
      end

      sig { params(merchant_id: String, name: String).returns(String) }
      def self.merchant(merchant_id, name)
        parse("merchant:#{merchant_id}:#{name}").code
      end

      sig { returns(T::Boolean) }
      def clearing?
        kind == :clearing
      end

      # 'D' or 'C', as stored.
      sig { returns(String) }
      def normal_side_column
        normal_side == :debit ? 'D' : 'C'
      end
    end
  end
end
