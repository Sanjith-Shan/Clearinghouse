# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Experiments
    module ReconciliationMonth
      # The two things the payouts work will own that a month of traffic needs, done
      # the simplest correct way until it lands: moving each capture's net from
      # pending to available after the merchant's payout delay (the job behind
      # Payments::Seams.schedule_availability), and paying available balances out
      # through the acquirer, with payout.paid and payout.failed posted from the
      # notification feed. Both post the money-flow table's own entries
      # (Ledger::Flows.funds_available, payout, payout_paid, payout_failed). The
      # reconciler does not read any of it; it is here so the ledger holds a
      # realistic month.
      class PayoutsStandIn
        extend T::Sig

        # Keep something back so a later dispute is less likely to go negative.
        PAYOUT_SHARE = Rational(9, 10)

        # A capture's net, waiting for the payout delay.
        class Pending < T::Struct
          const :flow_id, String
          const :merchant_id, String
          const :net, Money
          const :available_at, Time
        end

        # A payout sent, waiting for the bank.
        class Sent < T::Struct
          const :merchant_id, String
          const :amount, Money
        end

        sig { returns(T::Hash[String, Integer]) }
        attr_reader :counts

        sig { params(db: Sequel::Database, clock: Clock, acquirer: Acquirer::Client).void }
        def initialize(db:, clock:, acquirer:)
          @db = db
          @clock = clock
          @acquirer = acquirer
          @pending = T.let([], T::Array[Pending])
          @sent = T.let({}, T::Hash[String, Sent])
          @counts = T.let({}, T::Hash[String, Integer])
        end

        sig { params(flow_id: String, merchant: Merchant, gross: Money, at: Time).void }
        def captured(flow_id:, merchant:, gross:, at:)
          @pending << Pending.new(flow_id: flow_id, merchant_id: merchant.id,
                                  net: merchant.fee_schedule.split(gross).first,
                                  available_at: at + (merchant.payout_delay_days * Clock::SECONDS_PER_DAY))
        end

        sig { void }
        def make_available!
          due, @pending = @pending.partition { |p| p.available_at <= @clock.now }
          due.each do |p|
            Ledger.post!(@db, flow_type: Ledger::Flows::PAYMENT, flow_id: p.flow_id, description: 'funds available',
                              effective_at: p.available_at,
                              entries: Ledger::Flows.funds_available(merchant_id: p.merchant_id, net: p.net))
          end
        end

        # Pays out most of the available balance, if it is positive.
        sig { params(handle: MerchantHandle).void }
        def pay_out!(handle)
          merchant_id = handle.merchant.id
          available = Ledger.balance(@db, Ledger::AccountCode.merchant(merchant_id, 'available'), handle.currency)
          amount = Money.of((available.amount * PAYOUT_SHARE).floor, handle.currency)
          return unless amount.positive?

          id = Ids.generate('po')
          outcome = @acquirer.payout(reference: id, merchant_id: merchant_id, amount: amount, idempotency_key: id)
          return bump('payouts_refused') unless outcome.is_a?(Acquirer::Approved)

          Ledger.post!(@db, flow_type: Ledger::Flows::PAYOUT, flow_id: id, description: "payout #{id}",
                            effective_at: @clock.now,
                            entries: Ledger::Flows.payout(merchant_id: merchant_id, amount: amount))
          @sent[id] = Sent.new(merchant_id: merchant_id, amount: amount)
          bump('payouts_sent')
        end

        sig { params(handlers: Acquirer::NotificationPoller::Handlers).returns(Acquirer::NotificationPoller::Handlers) }
        def register(handlers)
          handlers.register('payout.paid') { |db, notification| settle(db, notification, paid: true) }
          handlers.register('payout.failed') { |db, notification| settle(db, notification, paid: false) }
        end

        private

        sig { params(key: String).void }
        def bump(key)
          @counts[key] = @counts.fetch(key, 0) + 1
        end

        sig { params(db: Sequel::Database, notification: Acquirer::Notification, paid: T::Boolean).void }
        def settle(db, notification, paid:)
          id = T.cast(notification.data.fetch('reference'), String)
          sent = @sent.fetch(id)
          entries = if paid
                      Ledger::Flows.payout_paid(amount: sent.amount)
                    else
                      Ledger::Flows.payout_failed(merchant_id: sent.merchant_id, amount: sent.amount)
                    end
          Ledger.post!(db, flow_type: Ledger::Flows::PAYOUT, flow_id: id,
                           description: "payout #{id} #{notification.type}",
                           effective_at: notification.created_at, entries: entries)
          bump(paid ? 'payouts_paid' : 'payouts_failed')
        end
      end
    end
  end
end
