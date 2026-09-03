# typed: strict
# frozen_string_literal: true

require 'sequel'

module Clearinghouse
  # The double-entry ledger. History (accounts, transactions, entries) is
  # append-only and the database enforces it; corrections are reversals. See
  # docs/design/ledger.md for the money flows and docs/design/interfaces.md for the
  # contract other areas build against.
  module Ledger
    extend T::Sig

    # Posts one balanced transaction and returns its id. Runs inside the caller's
    # database transaction when one is open, otherwise opens its own.
    sig do
      params(db: Sequel::Database, flow_type: String, flow_id: String, description: String, effective_at: Time,
             entries: T::Array[Entry]).returns(Integer)
    end
    def self.post!(db, flow_type:, flow_id:, description:, effective_at:, entries:)
      Posting.new(db).post(flow_type: flow_type, flow_id: flow_id, description: description,
                           effective_at: effective_at, entries: entries)
    end

    # Posts the mirror image of a transaction, in the same flow, and returns the new
    # transaction's id. A transaction can be reversed once, and a reversal cannot be
    # reversed.
    sig { params(db: Sequel::Database, transaction_id: Integer, reason: String, effective_at: Time).returns(Integer) }
    def self.reverse!(db, transaction_id, reason:, effective_at:)
      Posting.new(db).reverse(transaction_id, reason: reason, effective_at: effective_at)
    end

    # The balance from account_balances, signed on the account's normal side. Zero
    # for an account that has never been posted to.
    sig { params(db: Sequel::Database, account: String, currency: String).returns(Money) }
    def self.balance(db, account, currency)
      Posting.new(db).balance(account, currency)
    end

    # The same, with the balance row locked FOR UPDATE until the caller's
    # transaction ends. For check-then-post sequences like "is there enough
    # available balance for this payout".
    sig { params(db: Sequel::Database, account: String, currency: String).returns(Money) }
    def self.balance_for_update(db, account, currency)
      Posting.new(db).balance(account, currency, lock: true)
    end
  end
end

require_relative 'ledger/errors'
require_relative 'ledger/account_code'
require_relative 'ledger/entry'
require_relative 'ledger/posting'
