# typed: true
# frozen_string_literal: true

require 'json'

module Clearinghouse
  # Everything that happens after the payment: the acquirer's notification feed,
  # disputes, settlement files and the reconciler that matches them against the
  # ledger. See docs/design/disputes.md and docs/design/reconciliation.md.
  module Settlement
    extend T::Sig

    # The handlers bin/poller runs with. Each area registers the notification types
    # it owns. payout.paid and payout.failed belong to payouts:
    #
    #   handlers.register('payout.paid') { |db, n| Payouts.handle_notification(db, n) }
    #
    # Until a type is registered, the poller stops at the first notification of it
    # rather than skip it.
    sig { returns(Acquirer::NotificationPoller::Handlers) }
    def self.notification_handlers
      Acquirer::NotificationPoller::Handlers.new
    end
  end
end

require_relative 'acquirer/notification_poller'
