# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    class Error < Clearinghouse::Error; end

    # The posting was rejected before anything was written.
    class InvalidPostingError < Error; end

    # An account code outside the grammar in docs/design/interfaces.md.
    class UnknownAccountError < InvalidPostingError; end

    # A flow_id already has transactions of another flow_type.
    class FlowTypeMismatchError < InvalidPostingError; end

    # Debits and credits differ in at least one currency. `imbalances` maps each
    # such currency to debits minus credits in minor units, so a caller (or a test)
    # can see exactly which currency is off and by how much.
    class UnbalancedError < InvalidPostingError
      extend T::Sig

      sig { returns(T::Hash[String, Integer]) }
      attr_reader :imbalances

      sig { params(imbalances: T::Hash[String, Integer]).void }
      def initialize(imbalances)
        @imbalances = imbalances
        detail = imbalances.sort.map do |currency, net|
          direction = net.positive? ? 'debits exceed credits' : 'credits exceed debits'
          "#{currency}: #{direction} by #{Money.of(net.abs, currency)}"
        end
        super("unbalanced ledger transaction (#{detail.join('; ')})")
      end
    end

    class TransactionNotFoundError < Error; end

    # The transaction already has a reversal. Reversing twice would undo it twice.
    class AlreadyReversedError < Error; end

    # The transaction is itself a reversal. See docs/design/ledger.md for why that
    # is refused instead of treated as "re-post the original".
    class NotReversibleError < Error; end

    # account_balances and ledger_entries disagree in a way posting cannot repair
    # (for example a balance row is missing). The checker reports the same thing.
    class BalanceStateError < Error; end
  end
end
