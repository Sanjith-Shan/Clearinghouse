# typed: strict
# frozen_string_literal: true

module Clearinghouse
  # Applying the bank's payout notifications. See payouts.rb.
  module Payouts
    extend T::Sig

    NOTIFICATION_TYPES = %w[payout.paid payout.failed].freeze

    # Applies a payout.paid or payout.failed notification from the bank. The
    # notification poller (the disputes area) calls this for every notification of
    # those types, at least once each, so it has to be idempotent:
    #
    # - :applied         the payout moved to paid (payout_clearing -> cash) or failed
    #                    (payout_clearing -> available), with its event, in one transaction
    # - :duplicate       the payout was already in that state; nothing written
    # - :unknown_payout  no payout has this reference
    # - :ignored         not a payout notification
    #
    # A notification that contradicts what we know (paid after failed, for a
    # canceled payout, or with another acquirer reference) raises
    # NotificationConflictError. Skipping it would hide a bug on one side or the
    # other, and money would sit in payout_clearing with nobody looking.
    sig do
      params(db: Sequel::Database, notification: Acquirer::Notification, clock: Clock,
             events: Balances::EventSink).returns(Symbol)
    end
    def self.handle_notification(db, notification, clock:, events: Balances::DEFAULT_EVENTS)
      return :ignored unless NOTIFICATION_TYPES.include?(notification.type)

      data = notification.data
      paid = notification.type == 'payout.paid'
      T.let(db.transaction do
        row = db[:payouts].where(id: data.fetch('reference')).for_update.first
        next :unknown_payout unless row

        payout = from_row(row)
        next :duplicate if payout.status == (paid ? 'paid' : 'failed')

        check_notification!(payout, notification)
        paid ? settle_paid(db, payout, data, clock, events) : settle_failed(db, payout, data, clock, events)
        :applied
      end, Symbol)
    end

    sig { params(payout: Payout, notification: Acquirer::Notification).void }
    def self.check_notification!(payout, notification)
      reference = notification.data['acquirer_reference']
      sent = payout.status == 'in_transit' || (payout.status == 'pending' && payout.recovery_point == 'bank_requested')
      unless sent
        raise NotificationConflictError, "#{notification.type} for payout #{payout.id}, which is #{payout.status}"
      end
      return if payout.acquirer_reference.nil? || payout.acquirer_reference == reference

      raise NotificationConflictError,
            "#{notification.type} for payout #{payout.id} names #{reference}, not #{payout.acquirer_reference}"
    end
    private_class_method :check_notification!

    sig do
      params(db: Sequel::Database, payout: Payout, data: T::Hash[String, T.untyped], clock: Clock,
             events: Balances::EventSink).void
    end
    def self.settle_paid(db, payout, data, clock, events)
      Ledger.post!(db, flow_type: Ledger::Flows::PAYOUT, flow_id: payout.id, description: 'payout paid',
                       effective_at: clock.now, entries: Ledger::Flows.payout_paid(amount: payout.amount))
      row = update!(db, payout.id, clock, status: 'paid', recovery_point: 'bank_recorded',
                                          acquirer_reference: data['acquirer_reference'])
      events.emit!(db, merchant_id: payout.merchant_id, type: 'payout.paid', object: from_row(row).to_api,
                       clock: clock)
    end
    private_class_method :settle_paid

    sig do
      params(db: Sequel::Database, payout: Payout, data: T::Hash[String, T.untyped], clock: Clock,
             events: Balances::EventSink).void
    end
    def self.settle_failed(db, payout, data, clock, events)
      Ledger.post!(db, flow_type: Ledger::Flows::PAYOUT, flow_id: payout.id, description: 'payout failed',
                       effective_at: clock.now,
                       entries: Ledger::Flows.payout_failed(merchant_id: payout.merchant_id, amount: payout.amount))
      row = update!(db, payout.id, clock, status: 'failed', recovery_point: 'bank_recorded',
                                          failure_code: data['failure_code'] || 'could_not_process',
                                          acquirer_reference: data['acquirer_reference'])
      events.emit!(db, merchant_id: payout.merchant_id, type: 'payout.failed', object: from_row(row).to_api,
                       clock: clock)
    end
    private_class_method :settle_failed
  end
end
