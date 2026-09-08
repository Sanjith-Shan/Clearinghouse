# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Balances
    # Where payouts and reviews report their state changes. The events outbox
    # (`Clearinghouse::Events.emit!`, the payments area) is not on main yet, so the
    # domain code emits through this seam and the default drops the event. Once the
    # outbox lands, DEFAULT_EVENTS becomes an adapter whose `emit!` is
    #
    #   Clearinghouse::Events.emit!(db, merchant_id:, type:, object:, clock:)
    #
    # and nothing else changes: every call already runs inside the transaction of the
    # state change it reports, which is what the outbox needs.
    module EventSink
      extend T::Sig
      extend T::Helpers

      interface!

      sig do
        abstract.params(db: Sequel::Database, merchant_id: String, type: String, object: T::Hash[String, T.untyped],
                        clock: Clock).void
      end
      def emit!(db, merchant_id:, type:, object:, clock:); end
    end

    # The event types this area emits. Each must be added to Events::TYPES when the
    # outbox lands.
    EVENT_TYPES = %w[payout.created payout.paid payout.failed payout.canceled
                     review.opened review.closed].freeze

    # Drops every event. The default until the outbox exists.
    class NullEventSink
      extend T::Sig
      include EventSink

      sig do
        override.params(db: Sequel::Database, merchant_id: String, type: String,
                        object: T::Hash[String, T.untyped], clock: Clock).void
      end
      def emit!(db, merchant_id:, type:, object:, clock:) # rubocop:disable Lint/UnusedMethodArgument
        raise ArgumentError, "unknown event type #{type}" unless EVENT_TYPES.include?(type)
      end
    end

    DEFAULT_EVENTS = T.let(NullEventSink.new, EventSink)
  end
end
