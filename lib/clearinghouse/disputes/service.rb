# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Disputes
    # The rules for disputes. Three things change one:
    #
    # - dispute.opened: record it, move the disputed amount and our fee out of the
    #   merchant's available balance into dispute_clearing and fee revenue, and emit
    #   charge.dispute.created.
    # - dispute.closed: won returns the amount to the merchant (the fee is kept);
    #   lost posts nothing, because the merchant was already debited at open and the
    #   acquirer's `dispute` settlement line clears dispute_clearing. Either emits
    #   charge.dispute.closed.
    # - the merchant accepting the loss (POST /v1/disputes/:id/close): lost, no posting.
    #
    # Each runs in one database transaction with its ledger posting and its event,
    # so a dispute, its money and its event exist together or not at all. The two
    # notification handlers run inside the poller's transaction.
    #
    # Ledger descriptions name the payment (`dispute dp_... opened on pi_...`), the
    # convention bin/explain uses to link a dispute to its payment.
    #
    # The ledger time of a posting is the acquirer's time (the notification's due
    # time), not the time we got round to polling. The reconciler matches settlement
    # lines by that date, so a slow poller must not shift it.
    class Service
      extend T::Sig

      sig do
        params(lookup: PaymentLookup, events: EventSink, clock: Clock, fee_policy: FeePolicy,
               crash_hook: T.nilable(T.proc.params(point: String).void)).void
      end
      def initialize(lookup:, events:, clock:, fee_policy: FeePolicy.new, crash_hook: nil)
        @lookup = lookup
        @events = events
        @clock = clock
        @fee_policy = fee_policy
        @crash_hook = crash_hook
      end

      sig { params(handlers: Acquirer::NotificationPoller::Handlers).returns(Acquirer::NotificationPoller::Handlers) }
      def register(handlers)
        handlers.register('dispute.opened') { |db, notification| opened(db, notification) }
        handlers.register('dispute.closed') { |db, notification| closed(db, notification) }
      end

      sig { params(db: Sequel::Database, notification: Acquirer::Notification).returns(Dispute) }
      def opened(db, notification)
        data = notification.data
        acquirer_id = string(data, 'dispute_id')
        db.transaction do
          # The poller already dedupes; this makes the handler safe to call directly.
          existing = Disputes.by_acquirer_id(db, acquirer_id)
          next existing if existing

          reference = string(data, 'acquirer_reference')
          payment = @lookup.by_acquirer_reference(db, reference)
          raise UnknownPaymentError, "#{acquirer_id} is for #{reference}, which matches no payment" unless payment

          amount = money(data)
          if amount.currency != payment.currency
            raise InconsistentNotificationError,
                  "#{acquirer_id} is in #{amount.currency}, payment #{payment.id} is in #{payment.currency}"
          end

          record_opened(db, notification, payment, amount)
        end
      end

      sig { params(db: Sequel::Database, notification: Acquirer::Notification).returns(Dispute) }
      def closed(db, notification)
        data = notification.data
        acquirer_id = string(data, 'dispute_id')
        db.transaction do
          dispute = Disputes.by_acquirer_id(db, acquirer_id, lock: true)
          # dispute.opened is always earlier in the feed and the poller stops on a
          # failure, so this is a bug or an unknown payment, and it must not be skipped.
          raise NotFoundError, "dispute.closed for #{acquirer_id}, which was never opened here" unless dispute

          case (outcome = string(data, 'outcome'))
          when 'won' then acquirer_won(db, dispute, notification.created_at)
          when 'lost' then acquirer_lost(db, dispute, notification.created_at)
          else raise InconsistentNotificationError, "#{acquirer_id} closed with unknown outcome #{outcome}"
          end
        end
      end

      # The merchant accepts the loss. Nothing moves: the money left their balance
      # when the dispute opened. Accepting twice returns the same dispute, so a
      # retried request is harmless.
      sig { params(db: Sequel::Database, merchant_id: String, id: String).returns(Dispute) }
      def accept(db, merchant_id:, id:)
        dispute = T.let(db.transaction do
          found = Disputes.find(db, merchant_id: merchant_id, id: id, lock: true)
          raise NotFoundError, "no dispute #{id}" unless found

          crash!('dispute_locked')
          next found if found.status == 'lost'
          raise AlreadyClosedError, "#{id} was already won" if found.status == 'won'

          closed = close!(db, found, status: 'lost', closed_by: 'merchant', at: @clock.now)
          crash!('effects_written')
          closed
        end, Dispute)
        crash!('committed')
        dispute
      end

      private

      sig do
        params(db: Sequel::Database, notification: Acquirer::Notification, payment: PaymentLookup::Payment,
               amount: Money).returns(Dispute)
      end
      def record_opened(db, notification, payment, amount)
        data = notification.data
        fee = @fee_policy.fee_for(amount.currency)
        id = Ids.generate('dp')
        txn = Ledger.post!(db, flow_type: Ledger::Flows::DISPUTE, flow_id: id,
                               description: "dispute #{id} opened on #{payment.id}",
                               effective_at: notification.created_at,
                               entries: Ledger::Flows.dispute_opened(merchant_id: payment.merchant_id, amount: amount,
                                                                     fee: fee))
        dispute = Dispute.new(
          id: id, merchant_id: payment.merchant_id, payment_intent: payment.id, amount: amount, fee: fee,
          reason: string(data, 'reason'), status: 'needs_response', closed_by: nil,
          acquirer_dispute_id: string(data, 'dispute_id'), acquirer_reference: string(data, 'acquirer_reference'),
          opened_transaction_id: txn,
          won_transaction_id: nil, created_at: notification.created_at, closed_at: nil
        )
        Disputes.insert!(db, dispute, now: @clock.now)
        emit(db, dispute, 'charge.dispute.created')
        dispute
      end

      # A win returns the disputed amount to the merchant. It also applies to a
      # dispute the merchant had accepted: the acquirer's ruling is what moves the
      # money, and the returned funds arrive in settlement whatever we recorded.
      sig { params(db: Sequel::Database, dispute: Dispute, at: Time).returns(Dispute) }
      def acquirer_won(db, dispute, at)
        return dispute if dispute.status == 'won'
        if dispute.closed_by == 'acquirer'
          raise InconsistentNotificationError, "#{dispute.id} was lost and is now reported won"
        end

        txn = Ledger.post!(db, flow_type: Ledger::Flows::DISPUTE, flow_id: dispute.id,
                               description: "dispute #{dispute.id} won on #{dispute.payment_intent}",
                               effective_at: at,
                               entries: Ledger::Flows.dispute_won(merchant_id: dispute.merchant_id,
                                                                  amount: dispute.amount))
        close!(db, dispute, status: 'won', closed_by: 'acquirer', at: at, won_transaction_id: txn)
      end

      sig { params(db: Sequel::Database, dispute: Dispute, at: Time).returns(Dispute) }
      def acquirer_lost(db, dispute, at)
        return dispute if dispute.status == 'lost' # the merchant accepted it first
        raise InconsistentNotificationError, "#{dispute.id} was won and is now reported lost" if dispute.status == 'won'

        close!(db, dispute, status: 'lost', closed_by: 'acquirer', at: at)
      end

      sig do
        params(db: Sequel::Database, dispute: Dispute, status: String, closed_by: String, at: Time,
               won_transaction_id: T.nilable(Integer)).returns(Dispute)
      end
      def close!(db, dispute, status:, closed_by:, at:, won_transaction_id: nil)
        closed = dispute.with(status: status, closed_by: closed_by, closed_at: at,
                              won_transaction_id: won_transaction_id)
        Disputes.save!(db, closed, now: @clock.now)
        emit(db, closed, 'charge.dispute.closed')
        closed
      end

      sig { params(db: Sequel::Database, dispute: Dispute, type: String).void }
      def emit(db, dispute, type)
        @events.emit!(db, merchant_id: dispute.merchant_id, type: type, object: dispute.to_api, clock: @clock)
      end

      sig { params(data: T::Hash[String, T.untyped]).returns(Money) }
      def money(data)
        amount = data['amount']
        raise InconsistentNotificationError, "amount #{amount.inspect} is not positive" unless
          amount.is_a?(Integer) && amount.positive?

        Money.of(amount, string(data, 'currency'))
      end

      sig { params(data: T::Hash[String, T.untyped], key: String).returns(String) }
      def string(data, key)
        value = data[key]
        raise InconsistentNotificationError, "notification has no #{key}" unless value.is_a?(String) && !value.empty?

        value
      end

      sig { params(point: String).void }
      def crash!(point)
        @crash_hook&.call(point)
      end
    end
  end
end
