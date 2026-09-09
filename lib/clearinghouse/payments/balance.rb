# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # GET /v1/balance, read from the ledger. `pending` is captured money not yet
    # available; `available` can be paid out and goes negative when refunds or
    # disputes take more than the merchant has (docs/design/ledger.md).
    module Balance
      extend T::Sig

      KINDS = %w[available pending].freeze

      sig { params(db: Sequel::Database, merchant: Merchant).returns(T::Hash[String, T.untyped]) }
      def self.to_api(db, merchant)
        codes = KINDS.map { |kind| Ledger::AccountCode.merchant(merchant.id, kind) }
        currencies = db[:ledger_accounts].where(code: codes).distinct.order(:currency).select_map(:currency)
        # A merchant that has never been paid still has a balance: zero in USD.
        currencies = ['usd'] if currencies.empty?
        body = { 'object' => 'balance' }
        KINDS.each do |kind|
          body[kind] = currencies.map do |currency|
            amount = Ledger.balance(db, Ledger::AccountCode.merchant(merchant.id, kind), currency).amount
            { 'amount' => amount, 'currency' => currency }
          end
        end
        body.merge('livemode' => false)
      end
    end
  end
end
