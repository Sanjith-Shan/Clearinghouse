# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    # Renders an Explain::Explanation as a table for a terminal: one block per
    # transaction with its entries in debit and credit columns, and one column
    # per clearing account showing its running net after each transaction, so
    # you can watch money enter clearing and leave it.
    module ExplainPrinter
      extend T::Sig

      ANSI = T.let({ green: "\e[32m", red: "\e[31m", bold: "\e[1m", dim: "\e[2m" }.freeze, T::Hash[Symbol, String])
      RESET = "\e[0m"

      # One table row: cell text plus how to style each cell.
      class Row < T::Struct
        const :cells, T::Array[String]
        const :styles, T::Array[T.nilable(Symbol)]
        const :separator_before, T::Boolean, default: false
      end
      private_constant :Row

      sig { params(explanation: Explain::Explanation, color: T::Boolean).returns(String) }
      def self.render(explanation, color: false)
        keys = explanation.clearing.keys
        headers = ['txn', 'effective (UTC)', 'transaction / account', 'debit', 'credit'] + clearing_headers(keys)
        rows = explanation.steps.each_with_index.flat_map { |step, i| step_rows(step, keys, i.positive?) }
        lines = [title(explanation, color), '', table(headers, rows, color), '', *verdict(explanation, color)]
        "#{lines.join("\n")}\n"
      end

      sig { params(explanation: Explain::Explanation, color: T::Boolean).returns(String) }
      def self.title(explanation, color)
        count = explanation.steps.length
        status = explanation.explained? ? paint('EXPLAINED', :green, color) : paint('NOT EXPLAINED', :red, color)
        noun = count == 1 ? 'transaction' : 'transactions'
        flow = paint("Flow #{explanation.flow_id}", :bold, color)
        "#{flow} · #{explanation.flow_type} · #{count} #{noun} · #{status}"
      end
      private_class_method :title

      # Clearing accounts are all platform accounts, so the prefix is noise. The
      # currency is only added when one code appears in several currencies.
      sig { params(keys: T::Array[Explain::ClearingKey]).returns(T::Array[String]) }
      def self.clearing_headers(keys)
        codes = keys.map(&:first)
        keys.map do |code, currency|
          short = code.delete_prefix('platform:')
          codes.count(code) > 1 ? "#{short} #{currency.upcase}" : short
        end
      end
      private_class_method :clearing_headers

      sig { params(step: Explain::Step, keys: T::Array[Explain::ClearingKey], separated: T::Boolean).returns(T::Array[Row]) }
      def self.step_rows(step, keys, separated)
        nets = keys.map { |key| step.clearing_after[key] }
        clearing = keys.zip(nets).map { |(_, currency), net| net.nil? ? '' : Money.of(net, currency).to_s }
        styles = nets.map { |net| net.nil? ? nil : clearing_style(net) }
        header = Row.new(cells: ["##{step.transaction_id}", step.effective_at.utc.strftime('%Y-%m-%d %H:%M:%S'),
                                 describe(step), '', '', *clearing],
                         styles: [:bold, :dim, :bold, nil, nil, *styles],
                         separator_before: separated)
        lines = step.lines.map do |line|
          amount = line.amount.to_s
          Row.new(cells: ['', '', "  #{line.account}", line.side == :debit ? amount : '',
                          line.side == :credit ? amount : '', *keys.map { '' }],
                  styles: [])
        end
        [header, *lines]
      end
      private_class_method :step_rows

      sig { params(step: Explain::Step).returns(String) }
      def self.describe(step)
        notes = []
        notes << "reverses ##{step.reverses_transaction_id}" if step.reverses_transaction_id
        notes << "reversed by ##{step.reversed_by}" if step.reversed_by
        notes.empty? ? step.description : "#{step.description} (#{notes.join(', ')})"
      end
      private_class_method :describe

      # Green once an account is back at zero, red while money sits in it.
      sig { params(net: Integer).returns(Symbol) }
      def self.clearing_style(net)
        net.zero? ? :green : :red
      end
      private_class_method :clearing_style

      # Debit, credit and clearing columns are right-aligned so amounts line up.
      sig { params(headers: T::Array[String], rows: T::Array[Row], color: T::Boolean).returns(String) }
      def self.table(headers, rows, color)
        widths = headers.each_index.map do |i|
          ([headers.fetch(i)] + rows.map { |r| r.cells.fetch(i) }).map(&:length).max.to_i
        end
        out = [rule(widths, '┌', '┬', '┐'), line(headers, headers.map { :bold }, widths, color),
               rule(widths, '├', '┼', '┤')]
        rows.each do |row|
          out << rule(widths, '├', '┼', '┤') if row.separator_before
          out << line(row.cells, row.styles, widths, color)
        end
        out << rule(widths, '└', '┴', '┘')
        out.join("\n")
      end
      private_class_method :table

      sig { params(widths: T::Array[Integer], left: String, middle: String, right: String).returns(String) }
      def self.rule(widths, left, middle, right)
        left + widths.map { |w| '─' * (w + 2) }.join(middle) + right
      end
      private_class_method :rule

      sig do
        params(cells: T::Array[String], styles: T::Array[T.nilable(Symbol)], widths: T::Array[Integer],
               color: T::Boolean).returns(String)
      end
      def self.line(cells, styles, widths, color)
        padded = cells.each_with_index.map do |cell, i|
          text = i >= 3 ? cell.rjust(widths.fetch(i)) : cell.ljust(widths.fetch(i))
          paint(text, styles[i], color)
        end
        "│ #{padded.join(' │ ')} │"
      end
      private_class_method :line

      sig { params(explanation: Explain::Explanation, color: T::Boolean).returns(T::Array[String]) }
      def self.verdict(explanation, color)
        if explanation.clearing.empty?
          ["#{paint('Explained', :green, color)}: this flow never touched a clearing account."]
        elsif explanation.explained?
          ["#{paint('Explained', :green, color)}: every clearing account this flow touched is back at zero."]
        else
          open = explanation.clearing.reject { |_, net| net.zero? }
          width = open.keys.map { |code, _| code.length }.max.to_i
          ["#{paint('Not explained', :red, color)}: money is still sitting in clearing.",
           *open.map do |(code, currency), net|
             "  #{code.ljust(width)}  #{paint(Money.of(net, currency).to_s, :red, color)}"
           end]
        end
      end
      private_class_method :verdict

      sig { params(text: String, style: T.nilable(Symbol), color: T::Boolean).returns(String) }
      def self.paint(text, style, color)
        return text unless color && style

        "#{ANSI.fetch(style)}#{text}#{RESET}"
      end
      private_class_method :paint
    end
  end
end
