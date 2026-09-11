# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Reconciliation
    # The data-quality job (bin/data-quality): the ledger's clearing report with an
    # SLA per flow type, the reconciler's open work, and the `missing` exceptions for
    # settlement lines that are overdue. Modelled on the clearing checks in Stripe's
    # Ledger post: it never needs to be told what a bug looks like, because money
    # that moved and did not come back is still sitting in a clearing account.
    class DataQuality
      extend T::Sig

      DAY = Clock::SECONDS_PER_DAY

      # Everything one run found.
      class Report < T::Struct
        extend T::Sig

        const :clearing, Ledger::Clearing::Report
        const :missing_raised, T::Array[String]
        const :open_exceptions, T::Hash[String, Integer]
        const :pending_lines, Integer

        sig { returns(T::Boolean) }
        def healthy?
          clearing.healthy? && missing_raised.empty?
        end
      end

      # How long a flow of each type may stay open, from its first transaction.
      # Payments and refunds settle lag_days later, plus the slack. A payout is paid
      # or failed a day after it is sent. A dispute's clearing account is open twice:
      # between opening and the acquirer's debit, and between a win and the returned
      # funds, which can be months after opening; the report ages flows from their
      # first transaction, so the dispute SLA covers the card networks' 120-day
      # response window. Missing dispute lines are still caught promptly, by the
      # MissingDetector, which ages each expected line from its own movement.
      sig { params(config: Config).returns(T::Hash[String, Integer]) }
      def self.default_slas(config)
        settle = (config.lag_days + config.slack_days) * DAY
        { Ledger::Flows::PAYMENT => settle, Ledger::Flows::REFUND => settle,
          Ledger::Flows::PAYOUT => (1 + config.slack_days) * DAY, Ledger::Flows::DISPUTE => 120 * DAY }
      end

      sig do
        params(db: Sequel::Database, clock: Clock, config: Config, slas: T.nilable(T::Hash[String, Integer])).void
      end
      def initialize(db:, clock:, config: Config.new, slas: nil)
        @db = db
        @clock = clock
        @config = config
        @slas = T.let(slas || DataQuality.default_slas(config), T::Hash[String, Integer])
      end

      # `raise_missing: false` reports without writing anything.
      sig { params(raise_missing: T::Boolean).returns(Report) }
      def run(raise_missing: true)
        missing = raise_missing ? MissingDetector.new(db: @db, clock: @clock, config: @config).run : []
        Report.new(
          clearing: Ledger::Clearing.report(@db, as_of: @clock.now, slas: @slas), missing_raised: missing,
          open_exceptions: @db[:reconciliation_exceptions].where(status: 'open').group_and_count(:reason)
                                                          .to_h { |row| [row.fetch(:reason), row.fetch(:count)] },
          pending_lines: @db[:settlement_lines].where(outcome: 'pending').count
        )
      end
    end
  end
end
