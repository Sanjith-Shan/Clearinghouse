# typed: strict
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'stringio'
require 'time'

module Clearinghouse
  # `bin/explain <id>`: the whole money trail of one flow, readable in a terminal.
  #
  # Takes a flow id (pi_, re_, dp_, po_) or a ledger transaction id (`42` or `#42`,
  # which explains the flow that transaction belongs to), and prints every transaction
  # with its entries and the running net of each clearing account the flow touched
  # (Ledger.explain and ExplainPrinter), the flows related to it, and a last line that
  # says EXPLAINED or OPEN with what is stuck and for how long. See docs/design/explain.md.
  module ExplainCli
    extend T::Sig

    USAGE = 'Usage: bin/explain <pi_...|re_...|dp_...|po_...|transaction id> [--json] [--db NAME] ' \
            '[--as-of TIME] [--[no-]color]'
    # Flow ids are the API object ids, so another flow's description can name them.
    FLOW_ID = /(?<![A-Za-z0-9_])(?:pi|re|dp|po)_[A-Za-z0-9]+(?![A-Za-z0-9_])/
    TRANSACTION_ID = /\A#?([0-9]{1,18})\z/
    ANSI = T.let({ green: "\e[32m", red: "\e[31m", bold: "\e[1m", dim: "\e[2m" }.freeze, T::Hash[Symbol, String])

    class UsageError < Clearinghouse::Error; end
    class NotFoundError < Clearinghouse::Error; end

    # Parsed command line. `color` nil means "if stdout is a terminal".
    class Options < T::Struct
      const :target, String
      const :json, T::Boolean, default: false
      const :db, T.nilable(String), default: nil
      const :as_of, T.nilable(Time), default: nil
      const :color, T.nilable(T::Boolean), default: nil
    end

    # Another flow linked to this one by the description convention.
    class Related < T::Struct
      const :flow_id, String
      const :flow_type, String
      # 'mentions' (the other flow's descriptions name this one: a refund of this
      # payment) or 'mentioned' (this flow's descriptions name it: the payment this
      # refund belongs to).
      const :relation, String
      const :explained, T::Boolean
    end

    # Everything the renderers need.
    class Trace < T::Struct
      extend T::Sig

      const :explanation, Ledger::Explain::Explanation
      const :transaction_id, T.nilable(Integer)
      const :related, T::Array[Related]
      const :as_of, Time

      sig { returns(Time) }
      def opened_at
        T.must(explanation.steps.first).effective_at
      end

      # Seconds since the flow's first transaction, the same age Ledger::Clearing uses
      # for SLAs. Zero if the ledger is dated after `as_of`.
      sig { returns(Integer) }
      def open_seconds
        [(as_of - opened_at).floor, 0].max
      end

      sig { returns(T::Hash[Ledger::Explain::ClearingKey, Integer]) }
      def stuck
        explanation.clearing.reject { |_, net| net.zero? }
      end

      # Merchants whose accounts the flow posted to, from the account codes.
      sig { returns(T::Array[String]) }
      def merchants
        explanation.steps.flat_map(&:lines).filter_map { |line| line.account[/\Amerchant:([^:]+):/, 1] }.uniq
      end
    end

    sig do
      params(argv: T::Array[String], stdout: T.any(IO, StringIO), stderr: T.any(IO, StringIO), clock: Clock,
             connect: T.proc.params(database: T.nilable(String)).returns(Sequel::Database)).returns(Integer)
    end
    def self.run(argv, stdout:, stderr:, clock:, connect: ->(database) { DB.connect(database: database) })
      options = parse(argv)
      db = connect.call(options.db)
      begin
        trace = trace(db, options.target, as_of: options.as_of || clock.now)
      ensure
        db.disconnect
      end
      color = options.color
      color = stdout.tty? && !ENV.key?('NO_COLOR') if color.nil?
      stdout.write(options.json ? render_json(trace) : render_text(trace, color: color))
      0
    rescue UsageError => e
      stderr.puts(e.message, USAGE)
      2
    rescue NotFoundError => e
      stderr.puts(e.message)
      1
    end

    sig { params(argv: T::Array[String]).returns(Options) }
    def self.parse(argv)
      json = T.let(false, T::Boolean)
      db = T.let(nil, T.nilable(String))
      as_of = T.let(nil, T.nilable(Time))
      color = T.let(nil, T.nilable(T::Boolean))
      rest = OptionParser.new do |o|
        o.on('--json') { json = true }
        o.on('--db NAME') { |v| db = v }
        o.on('--as-of TIME') { |v| as_of = parse_time(v) }
        o.on('--[no-]color') { |v| color = v }
      end.parse(argv)
      raise UsageError, 'Give exactly one id.' unless rest.length == 1

      Options.new(target: rest.fetch(0), json: json, db: db, as_of: as_of, color: color)
    rescue OptionParser::ParseError => e
      raise UsageError, e.message
    end

    sig { params(text: String).returns(Time) }
    def self.parse_time(text)
      Time.iso8601(text).utc
    rescue ArgumentError
      raise UsageError, "--as-of must be ISO 8601, like 2026-01-05T00:00:00Z, not #{text.inspect}"
    end

    sig { params(db: Sequel::Database, target: String, as_of: Time).returns(Trace) }
    def self.trace(db, target, as_of:)
      flow_id, transaction_id = resolve(db, target)
      explanation = begin
        Ledger.explain(db, flow_id)
      rescue Ledger::Explain::FlowNotFoundError
        raise NotFoundError, "No ledger transactions for #{flow_id}."
      end
      Trace.new(explanation: explanation, transaction_id: transaction_id, related: related(db, explanation),
                as_of: as_of)
    end

    # A transaction id explains the flow it belongs to; anything else is a flow id.
    sig { params(db: Sequel::Database, target: String).returns([String, T.nilable(Integer)]) }
    def self.resolve(db, target)
      match = TRANSACTION_ID.match(target)
      return [target, nil] unless match

      id = Integer(match[1], 10)
      flow_id = db[:ledger_transactions].where(id: id).get(:flow_id)
      raise NotFoundError, "No ledger transaction ##{id}." unless flow_id

      [flow_id, id]
    end

    # The ledger has no column linking a refund or dispute to its payment, so related
    # flows come from a convention: a transaction's description names the flow ids it
    # relates to ("refund re_... of pi_..."). Both directions are searched. This is a
    # full scan of descriptions, fine for an operator's tool and not for a hot path.
    sig { params(db: Sequel::Database, explanation: Ledger::Explain::Explanation).returns(T::Array[Related]) }
    def self.related(db, explanation)
      own = explanation.flow_id
      mentions = db[:ledger_transactions].exclude(flow_id: own)
                                         .where(Sequel.lit('strpos(description, ?) > 0', own))
                                         .select(:flow_id, :description).order(:id).all
                                         .select { |row| row.fetch(:description).scan(FLOW_ID).include?(own) }
                                         .map { |row| [row.fetch(:flow_id), 'mentions'] }
      mentioned = explanation.steps.flat_map { |step| step.description.scan(FLOW_ID) }
                             .reject { |id| id == own }.map { |id| [id, 'mentioned'] }
      (mentions + mentioned).uniq(&:first).filter_map do |flow_id, relation|
        other = Ledger.explain(db, flow_id)
        Related.new(flow_id: flow_id, flow_type: other.flow_type, relation: relation, explained: other.explained?)
      rescue Ledger::Explain::FlowNotFoundError
        nil # named in a description but never posted
      end
    end

    sig { params(trace: Trace, color: T::Boolean).returns(String) }
    def self.render_text(trace, color: false)
      explanation = trace.explanation
      lines = [header(trace, color)]
      if (id = trace.transaction_id)
        lines << paint("Transaction ##{id} is part of this flow.", :dim, color)
      end
      lines += ['', Ledger::ExplainPrinter.render_table(explanation, color: color), '', *related_lines(trace, color),
                '', verdict(trace, color)]
      "#{lines.join("\n")}\n"
    end

    sig { params(trace: Trace, color: T::Boolean).returns(String) }
    def self.header(trace, color)
      explanation = trace.explanation
      count = explanation.steps.length
      parts = [paint(explanation.flow_id, :bold, color), explanation.flow_type]
      merchants = trace.merchants
      parts << "merchant #{merchants.join(', ')}" unless merchants.empty?
      parts << "#{count} #{count == 1 ? 'transaction' : 'transactions'}"
      parts.join(' · ')
    end

    sig { params(trace: Trace, color: T::Boolean).returns(T::Array[String]) }
    def self.related_lines(trace, color)
      return ["Related flows: none found #{paint('(matched by flow id in descriptions)', :dim, color)}"] if
        trace.related.empty?

      id_width = trace.related.map { |r| r.flow_id.length }.max.to_i
      type_width = trace.related.map { |r| r.flow_type.length }.max.to_i
      own = trace.explanation.flow_id
      rows = trace.related.map do |r|
        how = r.relation == 'mentions' ? "names #{own}" : "named by #{own}"
        status = r.explained ? paint('EXPLAINED', :green, color) : paint('OPEN', :red, color)
        "  #{r.flow_id.ljust(id_width)}  #{r.flow_type.ljust(type_width)}  #{how.ljust(own.length + 9)}  #{status}"
      end
      ['Related flows', *rows]
    end

    sig { params(trace: Trace, color: T::Boolean).returns(String) }
    def self.verdict(trace, color)
      explanation = trace.explanation
      if explanation.clearing.empty?
        return "#{paint('EXPLAINED', :green, color)}  this flow never touched a clearing account"
      end

      if explanation.explained?
        codes = explanation.clearing.keys.map(&:first).uniq.join(', ')
        return "#{paint('EXPLAINED', :green, color)}  every clearing account this flow touched is back at zero " \
               "(#{codes})"
      end

      stuck = trace.stuck.map do |(code, currency), net|
        "#{paint(Money.of(net, currency).to_s, :red, color)} in #{code}"
      end
      "#{paint('OPEN', :red, color)}  #{stuck.join(', ')} · open #{duration(trace.open_seconds)} " \
        "(since #{stamp(trace.opened_at)}, as of #{stamp(trace.as_of)})"
    end

    # "3d 4h", "4h 5m", "12m", "40s": the two largest units, which is as precise as
    # anyone reading "how long has this been stuck" needs.
    sig { params(seconds: Integer).returns(String) }
    def self.duration(seconds)
      units = [['d', 86_400], ['h', 3600], ['m', 60], ['s', 1]]
      parts = units.each_with_object([]) do |(name, size), out|
        value, seconds = seconds.divmod(size)
        out << "#{value}#{name}" if value.positive? || !out.empty?
      end
      parts.empty? ? '0s' : parts.first(2).join(' ')
    end

    sig { params(time: Time).returns(String) }
    def self.stamp(time)
      time.utc.strftime('%Y-%m-%d %H:%M UTC')
    end

    sig { params(trace: Trace).returns(String) }
    def self.render_json(trace)
      explanation = trace.explanation
      open = !explanation.explained?
      body = {
        'flow_id' => explanation.flow_id, 'flow_type' => explanation.flow_type,
        'requested_transaction_id' => trace.transaction_id, 'merchants' => trace.merchants,
        'status' => open ? 'open' : 'explained', 'as_of' => trace.as_of.utc.iso8601,
        'opened_at' => trace.opened_at.utc.iso8601, 'open_seconds' => open ? trace.open_seconds : nil,
        'stuck' => trace.stuck.map { |key, net| clearing_json(key, net) },
        'transactions' => explanation.steps.map { |step| step_json(step) },
        'related' => trace.related.map(&:serialize)
      }
      "#{JSON.pretty_generate(body)}\n"
    end

    sig { params(step: Ledger::Explain::Step).returns(T::Hash[String, T.untyped]) }
    def self.step_json(step)
      {
        'id' => step.transaction_id, 'description' => step.description,
        'effective_at' => step.effective_at.utc.iso8601,
        'reverses_transaction_id' => step.reverses_transaction_id, 'reversed_by' => step.reversed_by,
        'entries' => step.lines.map do |line|
          { 'account' => line.account, 'kind' => line.kind.to_s, 'side' => line.side.to_s,
            'amount' => line.amount.amount, 'currency' => line.amount.currency, 'display' => line.amount.to_s }
        end,
        'clearing_after' => step.clearing_after.map { |key, net| clearing_json(key, net) }
      }
    end

    sig { params(key: Ledger::Explain::ClearingKey, net: Integer).returns(T::Hash[String, T.untyped]) }
    def self.clearing_json(key, net)
      code, currency = key
      { 'account' => code, 'currency' => currency, 'amount' => net, 'display' => Money.of(net, currency).to_s }
    end

    sig { params(text: String, style: Symbol, color: T::Boolean).returns(String) }
    def self.paint(text, style, color)
      color ? "#{ANSI.fetch(style)}#{text}\e[0m" : text
    end

    private_class_method :header, :related_lines, :verdict, :stamp, :step_json, :clearing_json, :paint
  end
end
