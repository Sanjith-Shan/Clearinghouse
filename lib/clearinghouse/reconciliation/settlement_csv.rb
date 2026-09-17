# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Reconciliation
    # The acquirer's settlement CSV. Every field is an id, an integer, a currency code,
    # a type name or a date, so the format has no quoting and a split on commas is an
    # exact parser. Anything that does not fit is refused as a whole file: a
    # reconciler that skipped the rows it could not read would report a clean day.
    module SettlementCsv
      extend T::Sig

      HEADER = %w[line_id type acquirer_reference operation_id amount fee currency settled_on].freeze
      INTEGER = /\A-?\d+\z/

      # One row, in file order (`position` counts from 1).
      class Line < T::Struct
        const :position, Integer
        const :line_id, String
        const :type, String
        const :acquirer_reference, String
        const :operation_id, String
        const :amount, Integer
        const :fee, Integer
        const :currency, String
        const :settled_on, Date
      end

      sig { params(csv: String, date: Date).returns(T::Array[Line]) }
      def self.parse(csv, date:)
        header, *rows = csv.lines.map(&:chomp)
        raise MalformedFileError, "unexpected header #{header.inspect}" unless header&.split(',', -1) == HEADER

        rows.each_with_index.map { |row, index| line(row, index + 1, date) }
      end

      sig { params(row: String, position: Integer, date: Date).returns(Line) }
      def self.line(row, position, date)
        fields = row.split(',', -1)
        fail!(position, "has #{fields.length} fields") unless fields.length == HEADER.length
        line_id, type, reference, operation_id, amount, fee, currency, settled_on = fields.map(&:to_s)
        fail!(position, "has unknown type #{type}") unless LINE_TYPES.include?(type)
        [line_id, reference, operation_id].each { |id| fail!(position, 'has an empty id') if id.to_s.empty? }
        fail!(position, "has unknown currency #{currency}") unless Currency.known?(currency.to_s)
        fail!(position, "settles on #{settled_on}, not #{date}") unless settled_on == date.iso8601

        Line.new(position: position, line_id: line_id.to_s, type: type.to_s, acquirer_reference: reference.to_s,
                 operation_id: operation_id.to_s, amount: integer(amount, position),
                 fee: integer(fee, position), currency: Currency.normalize(currency.to_s), settled_on: date)
      end
      private_class_method :line

      sig { params(text: T.nilable(String), position: Integer).returns(Integer) }
      def self.integer(text, position)
        fail!(position, "has a non-integer amount #{text.inspect}") unless INTEGER.match?(text.to_s)

        Integer(text.to_s, 10)
      end
      private_class_method :integer

      sig { params(position: Integer, problem: String).returns(T.noreturn) }
      def self.fail!(position, problem)
        raise MalformedFileError, "line #{position} #{problem}"
      end
      private_class_method :fail!
    end
  end
end
