# typed: true
# frozen_string_literal: true

require 'date'

module AcquirerSim
  # Daily settlement files: what money actually moved, per day, as the acquirer
  # reports it, with discrepancies injected on command. Callers hold the simulator's
  # mutex.
  #
  # The unit is a Movement: a capture, refund, dispute or won-dispute reversal, each
  # due to settle settlement_lag_days after it happened. The one rule everything else
  # hangs on: **a movement is emitted in exactly one file**, the first file generated
  # whose date is on or after its due date (later, if a `late` injection deferred it),
  # or in none if a `missing` injection dropped it. Files are frozen once generated,
  # so asking for a date again returns the same bytes.
  class Settlement
    extend T::Sig

    HEADER = %w[line_id type acquirer_reference operation_id amount fee currency settled_on].freeze
    DISCREPANCY_TYPES = %w[missing duplicate amount_mismatch fee_mismatch late unknown_payment].freeze
    TARGETED = %w[missing duplicate amount_mismatch fee_mismatch late].freeze

    # Money that moved at the acquirer. `amount` is signed from the platform's side
    # (a refund or dispute is negative), and cash received is amount - fee.
    class Movement < T::Struct
      extend T::Sig

      const :key, String
      const :type, String
      const :acquirer_reference, String
      const :operation_id, String
      const :amount, Integer
      const :fee, Integer
      const :currency, String
      const :happened_at, Time
      const :due_on, Date
      prop :deferred_until, T.nilable(Date)
      prop :emitted_in, T.nilable(Date)

      sig { returns(Date) }
      def effective_on
        deferred_until || due_on
      end

      sig { returns(String) }
      def line_id
        Ids.derive('ln', key)
      end
    end

    # One CSV row.
    class Line < T::Struct
      extend T::Sig

      const :line_id, String
      const :type, String
      const :acquirer_reference, String
      const :operation_id, String
      prop :amount, Integer
      prop :fee, Integer
      const :currency, String
      const :movement, T.nilable(Movement)

      sig { params(settled_on: Date).returns(T::Array[T.untyped]) }
      def row(settled_on)
        [line_id, type, acquirer_reference, operation_id, amount, fee, currency, settled_on.iso8601]
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def identity
        { 'line_id' => line_id, 'line_type' => type, 'acquirer_reference' => acquirer_reference,
          'operation_id' => operation_id }
      end
    end

    # A generated file and the ground truth of what was done to it.
    class SettlementFile < T::Struct
      const :date, Date
      const :csv, String
      const :manifest, T::Hash[String, T.untyped]
      const :inject_fingerprint, String
    end

    sig { void }
    def initialize
      @movements = T.let([], T::Array[Movement])
      @files = T.let({}, T::Hash[Date, SettlementFile])
    end

    # Refunds and disputes carry no acquirer fee: the fee on the original capture is
    # kept, and a chargeback fee, if any, is Clearinghouse's policy to charge.
    sig do
      params(type: String, source_id: String, acquirer_reference: String, amount: Integer, currency: String,
             happened_at: Time, lag_days: Integer, fee: Integer).void
    end
    def record(type:, source_id:, acquirer_reference:, amount:, currency:, happened_at:, lag_days:, fee: 0)
      @movements << Movement.new(key: "#{type}|#{source_id}", type: type, acquirer_reference: acquirer_reference,
                                 operation_id: source_id, amount: amount, fee: fee, currency: currency,
                                 happened_at: happened_at, due_on: happened_at.utc.to_date + lag_days)
    end

    sig { returns(T::Array[Movement]) }
    def movements
      @movements.map(&:dup)
    end

    sig { params(date: Date).returns(T.nilable(SettlementFile)) }
    def file(date)
      @files[date]
    end

    sig do
      params(date: Date, sim_time: Time, inject: T::Array[T::Hash[String, T.untyped]], default_seed: Integer,
             fee_for: T.proc.params(amount: Integer, currency: String).returns(Integer)).returns(SettlementFile)
    end
    def generate(date, sim_time:, inject:, default_seed:, &fee_for)
      fingerprint = Params.fingerprint('settlement_file', { 'inject' => inject })
      existing = @files[date]
      if existing
        return existing if existing.inject_fingerprint == fingerprint

        raise RequestError.new(409, 'settlement_file_exists',
                               "the #{date} file was already generated with different injections")
      end
      if sim_time < Time.utc(date.year, date.month, date.day)
        raise RequestError.new(409, 'settlement_date_in_future', "Sim-Time #{sim_time.iso8601} is before #{date}")
      end

      Builder.new(date, due(date, sim_time), inject, default_seed, fee_for).build(fingerprint).tap do |file|
        @files[date] = file
      end
    end

    private

    sig { params(date: Date, sim_time: Time).returns(T::Array[Movement]) }
    def due(date, sim_time)
      @movements.select { |m| m.emitted_in.nil? && m.happened_at <= sim_time && m.effective_on <= date }
    end

    # Builds one file. Validates every injection before touching any movement, so a
    # refused request leaves the books as they were.
    class Builder
      extend T::Sig

      sig do
        params(date: Date, movements: T::Array[Movement], inject: T::Array[T::Hash[String, T.untyped]],
               default_seed: Integer, fee_for: T.proc.params(amount: Integer, currency: String).returns(Integer)).void
      end
      def initialize(date, movements, inject, default_seed, fee_for)
        @date = date
        @movements = movements
        @inject = inject
        @default_seed = default_seed
        @fee_for = fee_for
        @lines = T.let(movements.map { |m| line_for(m) }.sort_by(&:line_id), T::Array[Line])
        @plan = T.let([], T::Array[T::Hash[String, T.untyped]])
        @targeted = T.let({}, T::Hash[String, T::Boolean])
      end

      sig { params(fingerprint: String).returns(SettlementFile) }
      def build(fingerprint)
        @inject.each_with_index { |item, i| item.key?('random') ? plan_random(item, i) : plan_explicit(item) }
        output = @lines.dup
        discrepancies = @plan.each_with_index.map { |step, i| apply(step, i, output) }
        @movements.each do |m|
          deferred = m.deferred_until
          m.emitted_in = @date unless deferred && deferred > @date
        end
        # Written by hand rather than with the csv library: every field is an id, an
        # integer, a validated currency code, a fixed type name or a date the
        # simulator produced, so none can contain a comma, quote or newline.
        rows = output.sort_by.with_index { |line, i| [line.line_id, i] }.map { |line| line.row(@date).join(',') }
        csv = ([HEADER.join(',')] + rows).map { |row| "#{row}\n" }.join
        SettlementFile.new(date: @date, csv: csv, inject_fingerprint: fingerprint,
                           manifest: manifest(output, discrepancies))
      end

      private

      sig { params(movement: Movement).returns(Line) }
      def line_for(movement)
        Line.new(line_id: movement.line_id, type: movement.type, acquirer_reference: movement.acquirer_reference,
                 operation_id: movement.operation_id, amount: movement.amount, fee: movement.fee,
                 currency: movement.currency, movement: movement)
      end

      sig { params(item: T::Hash[String, T.untyped]).void }
      def plan_explicit(item)
        type = item['type']
        unless DISCREPANCY_TYPES.include?(type)
          raise Params.invalid("inject type must be one of #{DISCREPANCY_TYPES.join(', ')}", 'inject')
        end

        step = { 'type' => type, 'delta' => positive(item, 'delta', 1), 'days' => positive(item, 'days', 1) }
        if type == 'unknown_payment'
          step['amount'] = positive(item, 'amount', 1_000)
          step['currency'] = item['currency'].nil? ? 'usd' : Params.currency(item)
        else
          step['line'] = target(item)
        end
        @plan << step
      end

      # `{random: N, seed: S, types: [...]}` expands into N explicit discrepancies,
      # drawn from their own RNG so the traffic stream is untouched. Each line is
      # targeted at most once; when every line is taken, only unknown_payment is left.
      sig { params(item: T::Hash[String, T.untyped], index: Integer).void }
      def plan_random(item, index)
        count = item['random']
        unless count.is_a?(Integer) && count >= 0
          raise Params.invalid('random must be a non-negative integer', 'inject')
        end

        types = item.fetch('types', DISCREPANCY_TYPES)
        unless types.is_a?(Array) && !types.empty? && (types - DISCREPANCY_TYPES).empty?
          raise Params.invalid('types must be a non-empty list of discrepancy types', 'inject')
        end

        rng = Random.new(item.fetch('seed', @default_seed + index))
        count.times { @plan << random_step(rng, types) }
      end

      sig { params(rng: Random, types: T::Array[String]).returns(T::Hash[String, T.untyped]) }
      def random_step(rng, types)
        type = T.must(types[rng.rand(types.size)])
        free = @lines.reject { |line| @targeted[line.line_id] }
        type = 'unknown_payment' if free.empty? && TARGETED.include?(type)
        step = T.let({ 'type' => type, 'delta' => rng.rand(1..500), 'days' => 1 }, T::Hash[String, T.untyped])
        if type == 'unknown_payment'
          step.merge('amount' => rng.rand(500..50_000), 'currency' => 'usd')
        else
          line = T.must(free[rng.rand(free.size)])
          @targeted[line.line_id] = true
          step.merge('line' => line)
        end
      end

      sig { params(item: T::Hash[String, T.untyped]).returns(Line) }
      def target(item)
        reference = Params.string(item, 'acquirer_reference')
        kind = item['line_type']
        line = @lines.find { |l| l.acquirer_reference == reference && (kind.nil? || l.type == kind) }
        unless line
          raise RequestError.new(422, 'discrepancy_target_not_found',
                                 "no #{kind || 'line'} for #{reference} in the #{@date} file", param: 'inject')
        end
        if @targeted[line.line_id]
          raise RequestError.new(422, 'discrepancy_conflict', "#{line.line_id} is already targeted", param: 'inject')
        end

        @targeted[line.line_id] = true
        line
      end

      sig { params(item: T::Hash[String, T.untyped], name: String, default: Integer).returns(Integer) }
      def positive(item, name, default)
        item[name].nil? ? default : Params.positive_amount(item, name)
      end

      # Applies one planned discrepancy to the output lines and returns its manifest
      # entry: what the line should have been and what the file says instead.
      sig do
        params(step: T::Hash[String, T.untyped], index: Integer, output: T::Array[Line])
          .returns(T::Hash[String, T.untyped])
      end
      def apply(step, index, output)
        type = step.fetch('type')
        return unknown_payment(step, index, output) if type == 'unknown_payment'

        line = T.cast(step.fetch('line'), Line)
        entry = { 'type' => type }.merge(line.identity)
                                  .merge('expected' => { 'amount' => line.amount, 'fee' => line.fee })
        case type
        when 'missing'
          output.delete(line) # the movement is still marked emitted: this money never arrives
        when 'duplicate'
          output << line
        when 'amount_mismatch'
          line.amount = (line.amount.negative? ? -1 : 1) * (line.amount.abs + step.fetch('delta'))
        when 'fee_mismatch'
          line.fee += step.fetch('delta')
        when 'late'
          output.delete(line)
          deferred = @date + step.fetch('days')
          T.must(line.movement).deferred_until = deferred
          entry['deferred_to'] = deferred.iso8601
        end
        entry['actual'] = { 'amount' => line.amount, 'fee' => line.fee } unless %w[missing late].include?(type)
        entry
      end

      # A capture line for a reference that was never authorized. Its ids have the same
      # shape as real ones, so a reconciler has to look the reference up to catch it.
      sig do
        params(step: T::Hash[String, T.untyped], index: Integer, output: T::Array[Line])
          .returns(T::Hash[String, T.untyped])
      end
      def unknown_payment(step, index, output)
        salt = [@date.iso8601, index]
        amount = step.fetch('amount')
        currency = step.fetch('currency')
        line = Line.new(line_id: Ids.derive('ln', 'unknown', *salt), type: 'capture',
                        acquirer_reference: Ids.derive('acq', 'unknown', *salt),
                        operation_id: Ids.derive('op', 'unknown', *salt), amount: amount,
                        fee: @fee_for.call(amount, currency), currency: currency, movement: nil)
        output << line
        { 'type' => 'unknown_payment' }.merge(line.identity)
                                       .merge('actual' => { 'amount' => line.amount, 'fee' => line.fee })
      end

      sig do
        params(output: T::Array[Line], discrepancies: T::Array[T::Hash[String, T.untyped]])
          .returns(T::Hash[String, T.untyped])
      end
      def manifest(output, discrepancies)
        carried = output.uniq(&:line_id).filter_map do |line|
          movement = line.movement
          next if movement.nil? || movement.due_on >= @date

          line.identity.merge('due_on' => movement.due_on.iso8601, 'injected_late' => !movement.deferred_until.nil?)
        end
        { 'date' => @date.iso8601, 'line_count' => output.size, 'discrepancies' => discrepancies,
          'carried_over' => carried }
      end
    end
  end
end
