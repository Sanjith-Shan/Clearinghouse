# typed: true
# frozen_string_literal: true

require 'json'

module Experiments
  # Experiment 8's replay (sim/experiments/replay.rb): rows of the export.
  module Replay
    extend T::Sig

    # One line of RiskGate's replay export, `{payment_id, created, amount, currency,
    # risk_fields, is_fraud}`. The file is read where it lies and rows live only in this
    # process: the real one is IEEE-CIS data under Kaggle's rules, so nothing here
    # writes a row, or any field of one, anywhere. Reports carry aggregates only.
    class Row < T::Struct
      extend T::Sig

      KEYS = %w[payment_id created amount currency risk_fields is_fraud].freeze

      class MalformedError < StandardError; end

      # Position in the file, from 0. Used for idempotency keys instead of the row's
      # own payment_id, so no identifier from the data reaches Clearinghouse.
      const :index, Integer
      # Unix seconds. The simulated clock is moved here before the payment is
      # created, so RiskGate sees the transaction's own time as `created`.
      const :created, Integer
      # Minor units.
      const :amount, Integer
      const :currency, String
      # Passed to Clearinghouse, and so to RiskGate, exactly as read. RiskGate
      # rejects unknown keys, so none is ever added.
      const :risk_fields, T::Hash[String, T.untyped]
      const :fraud, T::Boolean

      sig { params(line: String, index: Integer).returns(Row) }
      def self.parse(line, index)
        hash = JSON.parse(line)
        raise MalformedError, "line #{index + 1} is not an object" unless hash.is_a?(Hash)

        missing = KEYS - hash.keys
        raise MalformedError, "line #{index + 1} lacks #{missing.join(', ')}" unless missing.empty?

        fields = hash.fetch('risk_fields')
        raise MalformedError, "line #{index + 1}: risk_fields is not an object" unless fields.is_a?(Hash)

        new(index: index, created: Integer(hash.fetch('created')), amount: Integer(hash.fetch('amount')),
            currency: String(hash.fetch('currency')).downcase, risk_fields: fields,
            fraud: fraud?(hash.fetch('is_fraud'), index))
      rescue JSON::ParserError, ArgumentError, TypeError => e
        raise MalformedError, "line #{index + 1}: #{e.message}"
      end

      sig { params(value: T.untyped, index: Integer).returns(T::Boolean) }
      def self.fraud?(value, index)
        case value
        when 1, true then true
        when 0, false then false
        else raise MalformedError, "line #{index + 1}: is_fraud is #{value.inspect}, want 0 or 1"
        end
      end
      private_class_method :fraud?

      # The simulator's test card for this row: the fraud-labelled ones use the card
      # that approves and then opens a fraudulent dispute, so their disputes arrive in
      # simulated time like real chargebacks.
      sig { returns(String) }
      def payment_method
        fraud ? 'pm_card_disputeFraudulent' : 'pm_card_visa'
      end
    end

    # Streams rows from `path`, at most `limit` (nil: all), without loading the file.
    sig { params(path: String, limit: T.nilable(Integer)).returns(T::Enumerator[Row]) }
    def self.read(path, limit: nil)
      Enumerator.new do |yielder|
        File.open(path) do |file|
          file.each_line.with_index do |line, index|
            break if limit && index >= limit
            next if line.strip.empty?

            yielder << Row.parse(line, index)
          end
        end
      end
    end
  end
end
