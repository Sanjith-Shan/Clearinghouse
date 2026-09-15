# typed: true
# frozen_string_literal: true

require 'prop_check'

module Clearinghouse
  module Testing
    module Model
      # Picks the next command from the model's current state, so most commands are
      # legal operations on objects that exist, weighted toward the interesting ones,
      # and a steady share are deliberately illegal: confirming a canceled payment,
      # capturing more than was authorized, refunding past the captured amount,
      # paying out more than is available, resolving a dispute that has not opened,
      # naming an object that does not exist.
      #
      # prop_check supplies the value generators (frequency, choose, one_of) driven
      # from one seeded Random, so a seed reproduces a sequence exactly. It has no
      # stateful testing of its own (its README says so), and its list shrinking only
      # shortens lists from the end, so the sequence is built here and shrunk by
      # Shrinker.
      class Generator
        extend T::Sig

        G = PropCheck::Generators

        CARDS = (Policy::APPROVING_CARDS + Policy::DECLINING_CARDS.keys).freeze
        ROUND_AMOUNTS = T.let({
          'usd' => [50, 100, 500, 1000, 1500, 2000, 2500, 10_000],
          'jpy' => [100, 500, 1000, 1500, 5000],
          'kwd' => [500, 1000, 1500, 5000, 10_000]
        }.freeze, T::Hash[String, T::Array[Integer]])
        MAX_AMOUNT = T.let({ 'usd' => 50_000, 'jpy' => 100_000, 'kwd' => 200_000 }.freeze, T::Hash[String, Integer])

        # Fee schedules for merchants after the first, which always has the default.
        MERCHANT_FEES = T.let([
          [290_000, { 'usd' => 30 }],
          [0, {}],
          [150_000, { 'usd' => 25, 'kwd' => 50 }]
        ].freeze, T::Array[[Integer, T::Hash[String, Integer]]])

        HOURS = [1, 6, 12, 24, 24, 48, 72].freeze

        # How often confirm uses each card.
        CONFIRM_CARDS = T.let({
          'pm_card_visa' => 5, 'pm_card_mastercard' => 1, 'pm_card_disputeFraudulent' => 3, 'pm_card_timeout' => 1,
          'pm_card_chargeDeclined' => 1, 'pm_card_insufficientFunds' => 1, 'pm_card_expired' => 1
        }.freeze, T::Hash[String, Integer])

        # `exclude_operations` and `exclude_cards` leave out what a system under test
        # cannot run yet (Sut#unsupported_operations, Sut#unsupported_payment_methods).
        sig do
          params(rng: Random, exclude_operations: T::Array[Symbol], exclude_cards: T::Array[String]).void
        end
        def initialize(rng, exclude_operations: [], exclude_cards: [])
          @rng = rng
          @exclude_operations = exclude_operations
          @exclude_cards = exclude_cards
        end

        sig { params(model: ReferenceModel).returns(Command) }
        def next_command(model)
          return create_merchant(model) if model.merchants.empty?

          T.cast(G.frequency(choices(model)).where { |c| !@exclude_operations.include?(c.op) }
                  .call(size: 10, rng: @rng), Command)
        end

        private

        sig { params(value: T.untyped).returns(PropCheck::Generator) }
        def const(value)
          G.constant(value)
        end

        sig { params(values: T::Array[T.untyped]).returns(PropCheck::Generator) }
        def pick(values)
          one_of(values.map { |v| G.constant(v) })
        end

        # Generators.one_of over a list built at run time.
        sig { params(generators: T::Array[PropCheck::Generator]).returns(PropCheck::Generator) }
        def one_of(generators)
          T.unsafe(G).one_of(*generators)
        end

        sig { params(operation: Symbol, args: PropCheck::Generator).returns(PropCheck::Generator) }
        def command(operation, **args)
          G.fixed_hash(args).map { |values| Command.new(op: operation, args: values.compact) }
        end

        # Weighted choices. Operations on objects are offered only when a suitable
        # object exists, so most of a sequence is legal and gets somewhere.
        sig { params(model: ReferenceModel).returns(T::Array[[Integer, PropCheck::Generator]]) }
        def choices(model)
          list = [[10, create_intent(model)], [6, advance], [4, const(Command.new(op: :settle))],
                  [4, const(Command.new(op: :availability_sweep))], [4, payout(model)]]
          list << [1, const(create_merchant(model))] if model.merchants.size < 3
          list + on_intents(model) + illegal(model, model.intents.values)
        end

        sig { params(model: ReferenceModel).returns(T::Array[[Integer, PropCheck::Generator]]) }
        def on_intents(model)
          intents = model.intents.values
          by_status = intents.group_by(&:status)
          confirmable = intents.select { |pi| ReferenceModel::CONFIRMABLE.include?(pi.status) }
          open_disputes = model.disputes.values.select { |d| d.status == 'open' }
          list = T.let([], T::Array[[Integer, PropCheck::Generator]])
          list << [8, confirm(confirmable.map(&:name))] unless confirmable.empty?
          list << [6, capture(by_status.fetch('requires_capture'))] if by_status.key?('requires_capture')
          list << [2, cancel(intents.map(&:name))] unless intents.empty?
          list << [7, refund(model, by_status.fetch('succeeded'))] if by_status.key?('succeeded')
          list << [4, resolve(open_disputes.map(&:intent), %w[won lost])] unless open_disputes.empty?
          list
        end

        # Commands the API must refuse without moving money.
        sig do
          params(model: ReferenceModel, intents: T::Array[ReferenceModel::IntentState])
            .returns(T::Array[[Integer, PropCheck::Generator]])
        end
        def illegal(model, intents)
          list = [[1, confirm(['pi_404'])]]
          settled = intents.reject { |pi| ReferenceModel::CONFIRMABLE.include?(pi.status) }
          list << [1, confirm(settled.map(&:name))] unless settled.empty?
          list << [1, command(:capture, intent: pick(intents.map(&:name)), amount: const(nil))] unless intents.empty?
          scheduled = model.disputes.values.reject { |d| d.status == 'open' }
          list << [1, resolve(scheduled.map(&:intent), %w[won lost])] unless scheduled.empty?
          list
        end

        sig { params(model: ReferenceModel).returns(Command) }
        def create_merchant(model)
          first = model.merchants.empty?
          rate, fixed = first ? T.must(MERCHANT_FEES.first) : T.must(MERCHANT_FEES.sample(random: @rng))
          Command.new(op: :create_merchant,
                      args: { merchant: model.next_name(:merchant), fee_rate_scaled: rate, fee_fixed: fixed })
        end

        sig { params(model: ReferenceModel).returns(PropCheck::Generator) }
        def create_intent(model)
          name = model.next_name(:intent)
          currency = G.frequency([[6, const('usd')], [2, const('jpy')], [2, const('kwd')]])
          currency.bind do |cur|
            command(:create_intent, intent: const(name), merchant: pick(model.merchants.keys), amount: amount(cur),
                                    currency: const(cur), capture_method: G.frequency([[3, const('automatic')],
                                                                                       [2, const('manual')]]),
                                    payment_method: G.frequency([[4, const(nil)], [1, pick(CARDS - @exclude_cards)]]))
          end
        end

        # Mostly ordinary amounts, often round ones (where half-even rounding of a
        # fee is decided), sometimes tiny ones, around and below the smallest amount
        # that covers the fee (31 cents at the default rate).
        sig { params(currency: String).returns(PropCheck::Generator) }
        def amount(currency)
          G.frequency([[5, G.choose(50..MAX_AMOUNT.fetch(currency))], [4, pick(ROUND_AMOUNTS.fetch(currency))],
                       [1, G.choose(1..60)]])
        end

        sig { params(names: T::Array[String]).returns(PropCheck::Generator) }
        def confirm(names)
          weighted = T.unsafe(CONFIRM_CARDS).except(*@exclude_cards)
          card = G.frequency(weighted.map { |name, weight| [weight, const(name)] })
          command(:confirm, intent: pick(names), payment_method: card)
        end

        sig { params(intents: T::Array[ReferenceModel::IntentState]).returns(PropCheck::Generator) }
        def capture(intents)
          pick(intents).bind do |pi|
            full = pi.capturable
            amounts = [[4, const(nil)], [1, const(full + 1)], [3, G.choose(1..full)]]
            command(:capture, intent: const(pi.name), amount: G.frequency(amounts))
          end
        end

        sig { params(names: T::Array[String]).returns(PropCheck::Generator) }
        def cancel(names)
          command(:cancel, intent: pick(names))
        end

        sig do
          params(model: ReferenceModel, succeeded: T::Array[ReferenceModel::IntentState]).returns(PropCheck::Generator)
        end
        def refund(model, succeeded)
          name = model.next_name(:refund)
          pick(succeeded).bind do |pi|
            remaining = pi.received - pi.refunded
            amounts = [[2, const(nil)], [1, const(remaining + 1)]]
            amounts << [4, G.choose(1..remaining)] if remaining.positive?
            command(:refund, refund: const(name), intent: const(pi.name), amount: G.frequency(amounts))
          end
        end

        sig { params(model: ReferenceModel).returns(PropCheck::Generator) }
        def payout(model)
          name = model.next_name(:payout)
          pairs = model.merchants.keys.product(Policy::CURRENCIES)
          funded = pairs.select { |m, c| model.available(m, c).positive? }
          pair = pick(pairs)
          pair = G.frequency([[4, pick(funded)], [1, pair]]) unless funded.empty?
          pair.bind do |(merchant, currency)|
            available = model.available(merchant, currency)
            amounts = [[4, const(nil)], [1, const(available.abs + 1)]]
            if available.positive?
              amounts << [3, G.choose(1..available)]
              # The simulator fails payouts whose amount ends in 13.
              if available >= 113
                failing = available - (available % 100) + 13
                amounts << [2, const(failing > available ? failing - 100 : failing)]
              end
            end
            command(:payout, payout: const(name), merchant: const(merchant), currency: const(currency),
                             amount: G.frequency(amounts))
          end
        end

        sig { returns(PropCheck::Generator) }
        def advance
          command(:advance_clock, hours: pick(HOURS))
        end

        sig { params(intents: T::Array[String], outcomes: T::Array[String]).returns(PropCheck::Generator) }
        def resolve(intents, outcomes)
          command(:resolve_dispute, intent: pick(intents), outcome: pick(outcomes))
        end
      end
    end
  end
end
