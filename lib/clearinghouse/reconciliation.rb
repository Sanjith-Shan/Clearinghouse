# typed: true
# frozen_string_literal: true

require 'date'
require 'digest'

module Clearinghouse
  # Matching the acquirer's settlement files against the ledger. Every line either
  # clears its flow (the settlement posting) or becomes a typed exception an operator
  # resolves. See docs/design/reconciliation.md.
  module Reconciliation
    extend T::Sig

    REASONS = %w[missing duplicate amount_mismatch fee_mismatch late unknown_payment].freeze
    LINE_TYPES = %w[capture refund dispute dispute_reversal].freeze

    class Error < Clearinghouse::Error; end
    # The file cannot be read as a settlement file. Nothing from it is written.
    class MalformedFileError < Error; end
    # A date we already ingested came back with different bytes. Settlement files are
    # frozen once generated, so this is a problem at the acquirer or in transit, and
    # no line of it is trusted.
    class FileChangedError < Error; end

    # Ingestion and the SLA job take this lock (for the length of their transaction),
    # so a `missing` exception can never be raised for a line that is being cleared in
    # a transaction the job cannot see yet.
    ADVISORY_LOCK_KEY = 0x5e771e

    sig { params(db: Sequel::Database).void }
    def self.lock!(db)
      raise Error, 'the reconciliation lock needs an open transaction' unless db.in_transaction?

      db.get(Sequel.function(:pg_advisory_xact_lock, ADVISORY_LOCK_KEY))
    end

    # What the reconciler has to agree with the acquirer about. The defaults are the
    # simulator's defaults (docs/design/sim.md): lines settle two days after the
    # movement, and the acquirer's fee on a capture is 1.5% plus 10 minor units of the
    # capture's currency, rounded half-even.
    class Config < T::Struct
      extend T::Sig

      const :lag_days, Integer, default: 2
      # How many files past its due date a line may arrive before the SLA job calls it
      # missing. One file of slack means a line that is a day late is reported `late`
      # when it arrives, not `missing` the day before.
      const :slack_days, Integer, default: 1
      const :acquirer_fee_rate_scaled, Integer, default: 150_000
      const :acquirer_fee_fixed, Integer, default: 10
      const :acquirer_fee_fixed_by_currency, T::Hash[String, Integer], default: {}

      # The fee the acquirer's contract says it may take on a capture of `gross`.
      sig { params(gross: Money).returns(Money) }
      def expected_acquirer_fee(gross)
        fixed = acquirer_fee_fixed_by_currency.fetch(gross.currency, acquirer_fee_fixed)
        FeeSchedule.new(rate_scaled: acquirer_fee_rate_scaled, fixed_minor: { gross.currency => fixed }).fee_for(gross)
      end

      # The date a movement that happened at `time` is due in a settlement file.
      sig { params(time: Time).returns(Date) }
      def due_on(time)
        time.utc.to_date + lag_days
      end
    end
  end
end

require_relative 'reconciliation/settlement_csv'
require_relative 'reconciliation/exceptions'
require_relative 'reconciliation/matcher'
require_relative 'reconciliation/ingestor'
