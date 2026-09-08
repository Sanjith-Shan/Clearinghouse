# typed: strict
# frozen_string_literal: true

require 'json'

module Clearinghouse
  # Payouts: money leaving a merchant's available balance for their bank.
  #
  #   available --(create)--> payout_clearing --(payout.paid)--> cash
  #                                           \--(payout.failed)--> available
  #
  # Creating a payout is split into atomic phases around the one foreign call, the
  # bank request, in the shape of Brandur Leach's recovery points (reading list 1).
  # RECOVERY_POINTS lists them in order; docs/design/payouts.md has what each phase
  # writes and what happens on a crash at each point.
  module Payouts
    extend T::Sig

    # In order. `started` and `finished` belong to the idempotency key (nothing
    # written yet; response stored). The three between are also stored on the
    # payout row, so a payout can be resumed without a key.
    RECOVERY_POINTS = %w[started balance_reserved bank_requested bank_recorded finished].freeze
    ROW_RECOVERY_POINTS = %w[balance_reserved bank_requested bank_recorded].freeze

    STATUSES = %w[pending in_transit paid failed canceled].freeze

    # What the bank's failure codes mean, for `failure_message`. Stripe's wording.
    FAILURE_MESSAGES = T.let({
      'account_closed' => 'The bank account has been closed.',
      'could_not_process' => 'The bank could not process this payout.'
    }.freeze, T::Hash[String, String])

    # A payout, as stored.
    class Payout < T::Struct
      extend T::Sig

      const :id, String
      const :merchant_id, String
      const :amount, Money
      const :status, String
      const :recovery_point, String
      const :automatic, T::Boolean
      const :scheduled_for, T.nilable(Date)
      const :description, T.nilable(String)
      const :metadata, T::Hash[String, String]
      const :reserve_transaction_id, Integer
      const :bank_idempotency_key, T.nilable(String)
      const :acquirer_reference, T.nilable(String)
      const :failure_code, T.nilable(String)
      const :arrival_date, Time
      const :created_at, Time

      sig { returns(T.nilable(String)) }
      def failure_message
        code = failure_code
        code && FAILURE_MESSAGES.fetch(code, 'The payout failed.')
      end

      # The latest-version API representation, Stripe's Payout object minus the
      # fields that need objects Clearinghouse does not have (destination,
      # balance_transaction).
      sig { returns(T::Hash[String, T.untyped]) }
      def to_api
        {
          'id' => id, 'object' => 'payout', 'amount' => amount.amount, 'currency' => amount.currency,
          'arrival_date' => arrival_date.to_i, 'automatic' => automatic, 'created' => created_at.to_i,
          'description' => description, 'failure_code' => failure_code,
          'failure_message' => failure_message,
          'metadata' => metadata, 'method' => 'standard', 'status' => status, 'livemode' => false
        }
      end
    end

    class Error < Clearinghouse::Error; end

    # The available balance cannot cover the payout: it is zero or negative, or
    # smaller than the amount asked for.
    class BalanceInsufficientError < Error
      extend T::Sig

      sig { returns(Money) }
      attr_reader :available

      sig { params(available: Money, requested: T.nilable(Money)).void }
      def initialize(available, requested)
        @available = available
        if requested
          super("available balance #{available} cannot cover a payout of #{requested}")
        else
          super("available balance is #{available}; there is nothing to pay out")
        end
      end
    end

    # Cancel on a payout that has already gone to the bank, or finished.
    class NotCancelableError < Error; end

    # A bank notification that contradicts what we recorded, for example payout.paid
    # for a payout we canceled. It means a bug on one side, so it stops the poller
    # rather than being skipped.
    class NotificationConflictError < Error; end

    class NotFoundError < Error; end

    sig { params(db: Sequel::Database, id: String, merchant_id: T.nilable(String)).returns(T.nilable(Payout)) }
    def self.find(db, id, merchant_id: nil)
      scope = db[:payouts].where(id: id)
      scope = scope.where(merchant_id: merchant_id) if merchant_id
      row = scope.first
      row ? from_row(row) : nil
    end

    # Newest first. `starting_after` is the id of the last payout of the previous
    # page, as in Stripe's list API. Returns the page and whether more follow.
    sig do
      params(db: Sequel::Database, merchant_id: String, limit: Integer, starting_after: T.nilable(String),
             status: T.nilable(String)).returns([T::Array[Payout], T::Boolean])
    end
    def self.list(db, merchant_id:, limit: 10, starting_after: nil, status: nil)
      scope = db[:payouts].where(merchant_id: merchant_id)
      scope = scope.where(status: status) if status
      if starting_after
        cursor = db[:payouts].where(id: starting_after, merchant_id: merchant_id).select(:created_at, :id).first
        raise NotFoundError, "no payout #{starting_after}" unless cursor

        scope = scope.where(Sequel.lit('(created_at, id) < (?, ?)', cursor.fetch(:created_at), cursor.fetch(:id)))
      end
      rows = scope.order(Sequel.desc(:created_at), Sequel.desc(:id)).limit(limit + 1).all
      [rows.first(limit).map { |row| from_row(row) }, rows.length > limit]
    end

    sig { params(row: T::Hash[Symbol, T.untyped]).returns(Payout) }
    def self.from_row(row)
      metadata = row.fetch(:metadata)
      metadata = JSON.parse(metadata) if metadata.is_a?(String)
      Payout.new(
        id: row.fetch(:id), merchant_id: row.fetch(:merchant_id),
        amount: Money.of(Integer(row.fetch(:amount)), row.fetch(:currency)), status: row.fetch(:status),
        recovery_point: row.fetch(:recovery_point), automatic: row.fetch(:automatic),
        scheduled_for: row[:scheduled_for], description: row[:description], metadata: metadata.to_h,
        reserve_transaction_id: Integer(row.fetch(:reserve_transaction_id)),
        bank_idempotency_key: row[:bank_idempotency_key], acquirer_reference: row[:acquirer_reference],
        failure_code: row[:failure_code], arrival_date: row.fetch(:arrival_date).utc,
        created_at: row.fetch(:created_at).utc
      )
    end

    sig { params(merchant_id: String).returns(String) }
    def self.available_account(merchant_id)
      Ledger::AccountCode.merchant(merchant_id, 'available')
    end
  end
end

require_relative 'payouts/phases'
require_relative 'payouts/notifications'
require_relative 'payouts/schedule'
