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

    # Every point where bin/poller can crash, per notification type it handles:
    # the background counterpart of Payments::Flows.registry.crash_points. It is
    # enumerated from the registered handlers, so a type registered here is in
    # experiment 2's matrix with no change to the harness (and fails there loudly
    # until it has a scenario). Names are `notification.<type>:<point>`, the value
    # CLEARINGHOUSE_CRASH_AT takes to crash bin/poller there.
    sig { returns(T::Array[Idempotency::Registry::CrashPoint]) }
    def self.background_crash_points
      notification_handlers(clock: Clock::Real.new).types.flat_map do |type|
        Acquirer::NotificationPoller::RECOVERY_POINTS.map do |point|
          Idempotency::Registry::CrashPoint.new(flow: Acquirer::NotificationPoller.flow_name(type), point: point,
                                                moment: :after_commit)
        end
      end
    end
  end
end

require_relative 'acquirer/notification_poller'
require_relative 'payment_lookup'
require_relative 'disputes'
require_relative 'reconciliation'
