# typed: true
# frozen_string_literal: true

require 'json'

module Clearinghouse
  # Everything that happens after the payment: the acquirer's notification feed,
  # disputes, settlement files and the reconciler that matches them against the
  # ledger. See docs/design/disputes.md and docs/design/reconciliation.md.
  module Settlement
    extend T::Sig

    # The handlers bin/poller runs with: each area registers the notification types
    # it owns, disputes (dispute.opened, dispute.closed) and payouts (payout.paid,
    # payout.failed). A type nobody registers stops the poller at the first
    # notification of it rather than being skipped.
    sig { params(clock: Clock).returns(Acquirer::NotificationPoller::Handlers) }
    def self.notification_handlers(clock:)
      handlers = Disputes::Service.new(clock: clock).register(Acquirer::NotificationPoller::Handlers.new)
      Payouts::NOTIFICATION_TYPES.each do |type|
        handlers.register(type) { |db, notification| Payouts.handle_notification(db, notification, clock: clock) }
      end
      handlers
    end
  end
end

require_relative 'acquirer/notification_poller'
require_relative 'payment_lookup'
require_relative 'disputes'
