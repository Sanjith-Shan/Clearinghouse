# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Balances
    # Where payouts and reviews report their state changes. Every call runs inside
    # the transaction of the state change it reports. The default writes to the
    # events outbox; specs pass a recording sink to see what was emitted.
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

    # The event types this area emits, all listed in Events::TYPES.
    EVENT_TYPES = %w[payout.created payout.paid payout.failed payout.canceled
                     review.opened review.closed].freeze

    # Writes each event to the transactional outbox (Events.emit!), so it commits
    # or rolls back with the change it reports.
    class OutboxEventSink
      extend T::Sig
      include EventSink

      sig do
        override.params(db: Sequel::Database, merchant_id: String, type: String,
                        object: T::Hash[String, T.untyped], clock: Clock).void
      end
      def emit!(db, merchant_id:, type:, object:, clock:)
        Events.emit!(db, merchant_id: merchant_id, type: type, object: object, clock: clock)
      end
    end

    DEFAULT_EVENTS = T.let(OutboxEventSink.new, EventSink)
  end
end
