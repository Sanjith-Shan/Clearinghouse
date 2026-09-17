# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Balances
    # Closing a risk review, approve or reject, as idempotent flows run by the
    # idempotency framework like every other mutating request
    # (docs/design/idempotency.md).
    module ReviewFlows
      extend T::Sig

      I = Idempotency

      # The review a request closes, from the path.
      class Input < T::Struct
        const :review_id, String
      end

      # Shared by approve and reject.
      class Base < Payments::Flows::Base
        extend T::Sig

        abstract!

        sig { override.params(hash: T::Hash[String, T.untyped]).returns(Input) }
        def load_input(hash) = Input.from_hash(hash)

        # Holds.close_hold! with its errors as the API's. Both are final answers
        # for this request, so they are stored against the key.
        sig { params(run: I::Run, db: Sequel::Database, decision: Symbol, refunds: RefundRequester).returns(Holds::Hold) }
        def close!(run, db, decision, refunds: DEFAULT_REFUNDS)
          c = ctx(run)
          Holds.close_hold!(db, review_id(run), merchant_id: c.merchant!.id, decision: decision, clock: c.clock,
                                                refunds: refunds)
        rescue Holds::NotFoundError
          raise Api::Errors::NotFoundError.resource('review', review_id(run))
        rescue Holds::AlreadyClosedError
          raise Api::Errors::InvalidRequestError.new("This review is already closed: #{review_id(run)}.",
                                                     code: 'review_closed')
        end

        sig { params(run: I::Run, db: Sequel::Database).returns(I::Response) }
        def render_review(run, db)
          hold = Holds.find(db, id: review_id(run), merchant_id: ctx(run).merchant!.id)
          run.render(T.must(hold).to_api)
        end

        sig { params(run: I::Run).returns(String) }
        def review_id(run) = T.cast(run.input, Input).review_id
      end

      # POST /v1/reviews/:id/reject. The review is closed and the payment's full
      # refund is created in one transaction; the refund then goes to the
      # acquirer through the refund flow's own phases. A reject that stops half
      # way (a crash, or no answer from the acquirer) is resumed from its key by
      # the client's retry or by the completer, like any refund, and the refund's
      # own id keeps the acquirer from refunding twice.
      #
      #   started -> refund_created -> refund_requested -> refund_recorded -> finished
      class Reject < Base
        sig { override.returns(String) }
        def name = 'review.reject'

        sig { override.returns(T::Array[I::Phase]) }
        def phases
          [
            I::Phase.new(from: I::STARTED, to: 'refund_created',
                         atomic: lambda { |run, db, _|
                           hold = close!(run, db, :reject, refunds: PaymentsRefundRequester.new(ctx(run)))
                           run.state['refund_id'] = T.must(hold.refund_id)
                           nil
                         },
                         # The refund reserves on the intent, like any refund of it.
                         queue_on: lambda { |run|
                           hold = Holds.find(ctx(run).db, id: review_id(run), merchant_id: ctx(run).merchant!.id)
                           Payments::Flows.intent_queue(hold&.flow_id || review_id(run))
                         }),
            *refund_phases,
            I::Phase.new(from: 'refund_recorded', to: I::FINISHED, atomic: ->(run, db, _) { render_review(run, db) })
          ]
        end
      end

      # POST /v1/reviews/:id/approve. One phase: whatever the hold has in held
      # goes to available, in the transaction that closes it.
      class Approve < Base
        sig { override.returns(String) }
        def name = 'review.approve'

        sig { override.returns(T::Array[I::Phase]) }
        def phases
          [I::Phase.new(from: I::STARTED, to: I::FINISHED, atomic: lambda { |run, db, _|
            close!(run, db, :approve)
            render_review(run, db)
          })]
        end
      end

      APPROVE = Approve.new
      REJECT = Reject.new
      Payments::Flows.registry.register(APPROVE)
      Payments::Flows.registry.register(REJECT)
    end
  end
end
