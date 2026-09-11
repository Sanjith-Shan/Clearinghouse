# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # One row of refunds.
    class Refund < T::Struct
      extend T::Sig

      const :id, String
      const :merchant_id, String
      const :payment_intent_id, String
      const :amount, Integer
      const :currency, String
      const :status, String
      const :reason, T.nilable(String), default: nil
      const :failure_reason, T.nilable(String), default: nil
      const :metadata, T::Hash[String, String], default: {}
      const :created_at, Time
      const :updated_at, Time

      REASONS = %w[duplicate fraudulent requested_by_customer].freeze

      sig { returns(Money) }
      def money = Money.of(amount, currency)

      # `charge` is the intent's latest_charge, which the caller passes because a
      # refund row does not store it.
      sig { params(charge: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
      def to_api(charge)
        {
          'id' => id,
          'object' => 'refund',
          'amount' => amount,
          'currency' => currency,
          'payment_intent' => payment_intent_id,
          'charge' => charge,
          'status' => status,
          'reason' => reason,
          'failure_reason' => failure_reason,
          'metadata' => metadata,
          'created' => created_at.to_i
        }
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(Refund) }
      def self.from_row(row)
        new(id: row.fetch(:id), merchant_id: row.fetch(:merchant_id), payment_intent_id: row.fetch(:payment_intent_id),
            amount: row.fetch(:amount), currency: row.fetch(:currency), status: row.fetch(:status),
            reason: row[:reason], failure_reason: row[:failure_reason],
            metadata: DB.from_json(row.fetch(:metadata)).to_h, created_at: row.fetch(:created_at).utc,
            updated_at: row.fetch(:updated_at).utc)
      end
    end

    # POST /v1/refunds, as steps (see Confirm for the shape).
    #
    #   reserve!   check the intent can be refunded, create the refund pending, and
    #              reserve its amount on the intent
    #   request    the acquirer refund, under the refund's own id as the key
    #   record!    succeeded: ledger and charge.refunded; failed: release the reservation
    #
    # Refunds do not lock the intent across the acquirer call, so several refunds
    # of one payment can be in flight at once. The reservation is what keeps them
    # from adding up to more than was captured: it is taken under the intent's row
    # lock, and the database's check constraint backs it up.
    module Refunds
      extend T::Sig

      # What the request asked for, parsed and validated by the route.
      class Input < T::Struct
        const :payment_intent_id, String
        const :amount, T.nilable(Integer)
        const :reason, T.nilable(String)
        const :metadata, T::Hash[String, String]
      end

      sig { params(db: Sequel::Database, ctx: Api::Context, id: String).returns(Refund) }
      def self.find!(db, ctx, id)
        row = db[:refunds].where(merchant_id: ctx.merchant!.id, id: id).first
        raise Api::Errors::NotFoundError.resource('refund', id) unless row

        Refund.from_row(row)
      end

      sig { params(db: Sequel::Database, ctx: Api::Context, refund: Refund).returns(T::Hash[String, T.untyped]) }
      def self.to_api(db, ctx, refund)
        intent = PaymentIntents.find!(db, merchant_id: ctx.merchant!.id, id: refund.payment_intent_id)
        refund.to_api(intent.latest_charge)
      end

      sig { params(db: Sequel::Database, ctx: Api::Context, input: Input).returns(Refund) }
      def self.reserve!(db, ctx, input)
        intent = PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: input.payment_intent_id,
                                          param: 'payment_intent')
        Errors.transition!(intent, StateMachine::Event::Refund)
        remaining = intent.amount_received - intent.amount_refunded
        amount = input.amount || remaining
        check_amount!(amount, remaining)

        now = ctx.clock.now
        refund = Refund.new(id: Ids.generate('re'), merchant_id: intent.merchant_id, payment_intent_id: intent.id,
                            amount: amount, currency: intent.currency, status: 'pending', reason: input.reason,
                            metadata: input.metadata, created_at: now, updated_at: now)
        db[:refunds].insert(id: refund.id, merchant_id: refund.merchant_id, payment_intent_id: intent.id,
                            amount: amount, currency: refund.currency, status: refund.status, reason: refund.reason,
                            metadata: DB.json(refund.metadata), created_at: now, updated_at: now)
        Support.save!(db, ctx, intent, intent.copy(amount_refunded: intent.amount_refunded + amount))
        refund
      end

      sig { params(amount: Integer, remaining: Integer).void }
      def self.check_amount!(amount, remaining)
        if remaining.zero?
          raise Api::Errors::InvalidRequestError.new('This payment has already been refunded in full.',
                                                     code: 'charge_already_refunded')
        end
        return if amount <= remaining

        raise Api::Errors::InvalidRequestError.invalid_parameter(
          'amount', "#{amount} is greater than the amount that can still be refunded (#{remaining})."
        )
      end
      private_class_method :check_amount!

      # The refund's own id is the acquirer key: one refund, one acquirer refund,
      # however many times the request is retried.
      sig { params(ctx: Api::Context, refund: Refund).returns(Acquirer::Outcome) }
      def self.request(ctx, refund)
        intent = PaymentIntents.find!(ctx.db, merchant_id: ctx.merchant!.id, id: refund.payment_intent_id)
        ctx.acquirer!.refund(acquirer_reference: T.must(intent.acquirer_reference), amount: refund.money,
                             idempotency_key: refund.id)
      end

      sig { params(ctx: Api::Context, refund: Refund).returns(Acquirer::LookupOutcome) }
      def self.look_up(ctx, refund)
        ctx.acquirer!.lookup(refund.id)
      end

      sig do
        params(db: Sequel::Database, ctx: Api::Context, refund_id: String,
               outcome: T.any(Acquirer::Approved, Acquirer::Declined)).returns(Refund)
      end
      def self.record!(db, ctx, refund_id, outcome)
        refund = Refund.from_row(T.must(db[:refunds].where(merchant_id: ctx.merchant!.id, id: refund_id)
                                                   .for_update.first))
        intent = PaymentIntents.lock!(db, merchant_id: ctx.merchant!.id, id: refund.payment_intent_id)
        raise Clearinghouse::Error, "refund #{refund.id} is already #{refund.status}" unless refund.status == 'pending'

        if outcome.is_a?(Acquirer::Approved)
          mark_succeeded(db, ctx, refund,
                         intent)
        else
          mark_failed(db, ctx, refund, intent, outcome)
        end
      end

      sig { params(db: Sequel::Database, ctx: Api::Context, refund: Refund, intent: PaymentIntent).returns(Refund) }
      def self.mark_succeeded(db, ctx, refund, intent)
        done = update(db, ctx, refund, status: 'succeeded')
        # The description names the payment: bin/explain links related flows by it
        # (docs/design/interfaces.md).
        Ledger.post!(db, flow_type: Ledger::Flows::REFUND, flow_id: refund.id,
                         description: "refund #{refund.id} of #{refund.payment_intent_id}",
                         effective_at: ctx.clock.now,
                         entries: Ledger::Flows.refund(merchant_id: refund.merchant_id, amount: refund.money))
        # If the payment's review was rejected, its held money goes back to available
        # in this transaction, as the refund takes the same amount out. A no-op otherwise.
        Balances::Holds.release_after_refund!(db, flow_id: refund.payment_intent_id, clock: ctx.clock)
        Support.emit!(db, ctx, 'charge.refunded', T.must(intent.charge_to_api))
        done
      end
      private_class_method :mark_succeeded

      sig do
        params(db: Sequel::Database, ctx: Api::Context, refund: Refund, intent: PaymentIntent,
               outcome: Acquirer::Declined).returns(Refund)
      end
      def self.mark_failed(db, ctx, refund, intent, outcome)
        done = update(db, ctx, refund, status: 'failed', failure_reason: outcome.code)
        Support.save!(db, ctx, intent, intent.copy(amount_refunded: intent.amount_refunded - refund.amount))
        Support.emit!(db, ctx, 'charge.refund.updated', done.to_api(intent.latest_charge))
        done
      end
      private_class_method :mark_failed

      sig do
        params(db: Sequel::Database, ctx: Api::Context, refund: Refund, status: String,
               failure_reason: T.nilable(String)).returns(Refund)
      end
      def self.update(db, ctx, refund, status:, failure_reason: nil)
        now = ctx.clock.now
        db[:refunds].where(id: refund.id).update(status: status, failure_reason: failure_reason, updated_at: now)
        refund.with(status: status, failure_reason: failure_reason, updated_at: now)
      end
      private_class_method :update
    end
  end
end
