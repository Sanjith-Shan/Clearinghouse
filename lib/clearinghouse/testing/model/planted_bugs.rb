# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # Deliberately broken copies of real code, injected into LedgerSut, to prove
      # the harness catches a bug and shrinks it to something a person can debug
      # (the spec's interview-defense item 10). Nothing outside the harness uses
      # them, and they never touch the real classes: each is a separate object
      # passed to the adapter.
      #
      #   bin/model-test --sut ledger --plant fee_rounding
      module PlantedBugs
        extend T::Sig

        # FeeSchedule#fee_for with the percentage rounded half *up*. Wrong by one
        # minor unit only when the percentage lands exactly on half a unit (2.9% of
        # $5.00 is 14.5 cents), which is why the generator favours round amounts.
        FEE_ROUNDING = T.let(lambda do |schedule, gross|
          variable = ((gross.amount * schedule.rate_scaled) + (FeeSchedule::SCALE / 2)) / FeeSchedule::SCALE
          Money.of(variable + schedule.fixed_minor.fetch(gross.currency, 0), gross.currency)
        end, LedgerSut::FeeCalculator)

        # Ledger::Flows with payout_failed skipping the clearing account: the money
        # returns to the merchant out of cash instead of out of payout_clearing. It
        # still balances, so the database accepts it.
        PayoutFailedSkipsClearing = Module.new do
          Ledger::Flows.singleton_methods(false).each do |name|
            define_singleton_method(name) { |**args| Ledger::Flows.public_send(name, **args) }
          end

          define_singleton_method(:payout_failed) do |merchant_id:, amount:|
            [Ledger::Entry.debit(Ledger::Flows::CASH, amount),
             Ledger::Entry.credit(Ledger::AccountCode.merchant(merchant_id, 'available'), amount)]
          end
        end

        NAMES = %w[fee_rounding payout_failed_skips_clearing].freeze

        # Keyword arguments for LedgerSut.new that plant the named bug.
        sig { params(name: String).returns(T::Hash[Symbol, T.untyped]) }
        def self.ledger_sut_args(name)
          case name
          when 'fee_rounding' then { fee: FEE_ROUNDING }
          when 'payout_failed_skips_clearing' then { flows: PayoutFailedSkipsClearing }
          else raise UnknownSutError, "unknown planted bug #{name.inspect}; known: #{NAMES.join(', ')}"
          end
        end
      end
    end
  end
end
