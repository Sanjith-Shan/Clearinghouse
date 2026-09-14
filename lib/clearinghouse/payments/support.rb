# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # Small helpers every operation uses: saving an intent with the request's
    # clock, emitting its event, and posting a capture to the ledger.
    module Support
      extend T::Sig

      sig { params(db: Sequel::Database, ctx: Api::Context, before: PaymentIntent, after: PaymentIntent).returns(PaymentIntent) }
      def self.save!(db, ctx, before, after)
        PaymentIntents.save!(db, before, after, now: ctx.clock.now)
      end

      sig { params(db: Sequel::Database, ctx: Api::Context, type: String, object: T::Hash[String, T.untyped]).returns(String) }
      def self.emit!(db, ctx, type, object)
        Events.emit!(db, merchant_id: ctx.merchant!.id, type: type, object: object, clock: ctx.clock,
                         request: ctx.event_request)
      end

      # The money-flow table's capture row, under the intent's flow id, and the
      # seam where the payouts work schedules the net to become available.
      sig { params(db: Sequel::Database, ctx: Api::Context, intent: PaymentIntent, gross: Money).void }
      def self.post_capture!(db, ctx, intent, gross)
        merchant = ctx.merchant!
        now = ctx.clock.now
        net, fee = merchant.fee_schedule.split(gross)
        entries = Ledger::Flows.capture(merchant_id: merchant.id, gross: gross, fee: fee)
        Ledger.post!(db, flow_type: Ledger::Flows::PAYMENT, flow_id: intent.id, description: 'capture',
                         effective_at: now, entries: entries)
        available_on = Balances::Availability.available_on(captured_at: now, delay_days: merchant.payout_delay_days)
        Seams.schedule_availability(db, flow_id: intent.id, merchant_id: merchant.id, net: net,
                                        available_on: available_on, clock: ctx.clock)
        # A payment RiskGate sent to review holds the merchant's payout of what was
        # captured (docs/design/risk-integration.md).
        Risk::Step.hold_on_capture!(db, risk: intent.risk, merchant_id: merchant.id, payment_intent_id: intent.id,
                                        amount_captured: gross, clock: ctx.clock)
      end

      # Our fee must not exceed what is captured, or the merchant's share would be
      # negative. With the default 2.9% + 30 cents that means at least 31 cents.
      sig { params(merchant: Merchant, amount: Money, param: String).void }
      def self.check_covers_fee!(merchant, amount, param)
        fee = merchant.fee_schedule.fee_for(amount)
        return if fee <= amount

        raise Api::Errors::InvalidRequestError.new(
          "#{param} must be at least enough to cover the fee (#{fee.amount} #{amount.currency} on #{amount.amount}).",
          code: 'amount_too_small', param: param
        )
      end

      # An acquirer answer that says nothing about the outcome. The intent stays
      # where it is, and the request can be retried.
      sig { params(outcome: T.any(Acquirer::Unknown, Acquirer::Unavailable)).returns(T.noreturn) }
      def self.acquirer_unavailable!(outcome)
        detail = if outcome.is_a?(Acquirer::Unknown)
                   'The card network did not answer, so the outcome is not known yet.'
                 else
                   'The card network is unavailable.'
                 end
        raise Api::Errors::AcquirerUnavailableError, detail
      end
    end
  end
end
