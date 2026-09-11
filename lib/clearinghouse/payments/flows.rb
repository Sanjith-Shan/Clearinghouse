# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # The mutating operations as idempotent flows: each step of an operation
    # (Confirm, Capture, Cancel, Refunds) becomes an atomic phase with a named
    # recovery point, and every acquirer call sits in a phase's foreign step,
    # outside any transaction. The rules every flow here follows:
    #
    # - A foreign call is made only from a phase that starts at a point named
    #   `*_requested`, committed before the call. Resuming at such a point means
    #   the call may already have happened, so the phase asks the acquirer under
    #   the same key first (Flows.definite) and only sends if the answer is
    #   "nothing under that key".
    # - The acquirer's answer is recorded, with its consequences (status, ledger,
    #   events), in the same transaction that advances past the point.
    # - An unknown answer changes nothing: the key stays at `*_requested`, the lease
    #   is given back, and the caller gets a retryable 503.
    #
    # docs/design/idempotency.md draws the confirm flow and says what a crash at
    # each point leaves behind.
    module Flows
      extend T::Sig

      I = Idempotency

      # The acquirer's definite answer for a foreign step. On a resumed phase the
      # step may already have reached the acquirer, so it looks first and only
      # sends when the acquirer has nothing under the key.
      sig do
        params(run: I::Run, send: T.proc.returns(Acquirer::Outcome),
               look_up: T.proc.returns(Acquirer::LookupOutcome)).returns(T.any(Acquirer::Approved, Acquirer::Declined))
      end
      def self.definite(run, send:, look_up:)
        outcome = if run.resumed
                    found = look_up.call
                    case found
                    when Acquirer::NotFound then send.call
                    when Acquirer::Unavailable then Support.acquirer_unavailable!(found)
                    else found
                    end
                  else
                    send.call
                  end
        case outcome
        when Acquirer::Unknown, Acquirer::Unavailable then Support.acquirer_unavailable!(outcome)
        else outcome
        end
      end

      # Shared plumbing for the flows below.
      class Base < I::Flow
        extend T::Sig

        abstract!

        sig { params(run: I::Run).returns(Api::Context) }
        def ctx(run) = T.cast(run.context, Api::Context)

        # A phase that only moves the recovery point: the commit before a foreign
        # call that says "this call may now have been made".
        sig { params(from: String, to: String).returns(I::Phase) }
        def checkpoint(from, to)
          I::Phase.new(from: from, to: to, atomic: ->(_run, _db, _foreign) {})
        end

        sig { params(run: I::Run, db: Sequel::Database, id: String).returns(I::Response) }
        def render_intent(run, db, id)
          run.render(PaymentIntents.find!(db, merchant_id: ctx(run).merchant!.id, id: id).to_api)
        end
      end

      # POST /v1/payment_intents: one phase, nothing foreign.
      class CreateIntent < Base
        sig { override.returns(String) }
        def name = 'payment_intent.create'

        sig { override.params(hash: T::Hash[String, T.untyped]).returns(Create::Input) }
        def load_input(hash) = Create::Input.from_hash(hash)

        sig { override.returns(T::Array[I::Phase]) }
        def phases
          [I::Phase.new(from: I::STARTED, to: I::FINISHED, atomic: lambda { |run, db, _|
            run.render(Create.create!(db, ctx(run), T.cast(run.input, Create::Input)).to_api)
          })]
        end
      end

      # POST /v1/payment_intents/:id/confirm.
      #
      #   started -> intent_locked -> risk_assessed -> authorization_requested
      #           -> authorization_recorded -> ledger_posted -> finished
      class ConfirmIntent < Base
        sig { override.returns(String) }
        def name = 'payment_intent.confirm'

        sig { override.params(hash: T::Hash[String, T.untyped]).returns(Confirm::Input) }
        def load_input(hash) = Confirm::Input.from_hash(hash)

        sig { override.returns(T::Array[I::Phase]) }
        def phases
          [lock_phase, risk_phase, checkpoint('risk_assessed', 'authorization_requested'), authorize_phase,
           I::Phase.new(from: 'authorization_recorded', to: 'ledger_posted', atomic: lambda { |run, db, _|
             Confirm.apply_approval!(db, ctx(run), input(run).intent_id)
             nil
           }),
           I::Phase.new(from: 'ledger_posted', to: I::FINISHED, atomic: lambda { |run, db, _|
             render_intent(run, db, input(run).intent_id)
           })]
        end

        sig { override.params(run: I::Run, db: Sequel::Database).void }
        def release(run, db)
          IntentLock.release(db, input(run).intent_id, run.key_id)
        end

        private

        # The new attempt: to processing, attempt + 1, the intent now ours.
        sig { returns(I::Phase) }
        def lock_phase
          I::Phase.new(from: I::STARTED, to: 'intent_locked', atomic: lambda { |run, db, _|
            intent = Confirm.lock!(db, ctx(run), input(run))
            IntentLock.take!(db, intent.id, run.key_id)
            nil
          })
        end

        # RiskGate, then its verdict stored before anything acts on it. A resume
        # past risk_assessed never asks RiskGate again for this attempt. The next
        # point, authorization_requested, is the promise that from then on the
        # acquirer may have been asked.
        sig { returns(I::Phase) }
        def risk_phase
          I::Phase.new(from: 'intent_locked', to: 'risk_assessed',
                       foreign: ->(run) { Confirm.assess_risk(ctx(run), intent(run)) },
                       atomic: lambda { |run, db, outcome|
                         blocked = Confirm.record_risk!(db, ctx(run), input(run).intent_id, outcome)
                         blocked ? run.render_error(blocked) : nil
                       })
        end

        # The authorization, or on resume the question "did you authorize this
        # attempt already?". A decline finishes the request here.
        sig { returns(I::Phase) }
        def authorize_phase
          I::Phase.new(from: 'authorization_requested', to: 'authorization_recorded',
                       foreign: lambda { |run|
                         Flows.definite(run, send: -> { Confirm.authorize(ctx(run), intent(run)) },
                                             look_up: -> { Confirm.look_up(ctx(run), intent(run)) })
                       },
                       atomic: lambda { |run, db, outcome|
                         recorded = Confirm.record_authorization!(db, ctx(run), input(run).intent_id, outcome)
                         if outcome.is_a?(Acquirer::Declined)
                           run.render_error(Errors.card_error(T.must(recorded.last_payment_error)))
                         end
                       })
        end

        sig { params(run: I::Run).returns(Confirm::Input) }
        def input(run) = T.cast(run.input, Confirm::Input)

        sig { params(run: I::Run).returns(PaymentIntent) }
        def intent(run)
          PaymentIntents.find!(ctx(run).db, merchant_id: ctx(run).merchant!.id, id: input(run).intent_id)
        end
      end

      # POST /v1/payment_intents/:id/capture.
      #
      #   started -> intent_locked -> capture_requested -> capture_recorded -> finished
      class CaptureIntent < Base
        sig { override.returns(String) }
        def name = 'payment_intent.capture'

        sig { override.params(hash: T::Hash[String, T.untyped]).returns(Capture::Input) }
        def load_input(hash) = Capture::Input.from_hash(hash)

        sig { override.returns(T::Array[I::Phase]) }
        def phases
          [
            # The amount is fixed here and carried in the key's state, so a resumed
            # capture sends exactly what the first run would have.
            I::Phase.new(from: I::STARTED, to: 'intent_locked', atomic: lambda { |run, db, _|
              intent, amount = Capture.check!(db, ctx(run), input(run))
              IntentLock.take!(db, intent.id, run.key_id)
              run.state['amount'] = amount.amount
              nil
            }),
            checkpoint('intent_locked', 'capture_requested'),
            I::Phase.new(from: 'capture_requested', to: 'capture_recorded',
                         foreign: lambda { |run|
                           Flows.definite(run, send: -> { Capture.request(ctx(run), intent(run), amount(run)) },
                                               look_up: -> { Capture.look_up(ctx(run), intent(run)) })
                         },
                         atomic: lambda { |run, db, outcome|
                           Capture.record!(db, ctx(run), input(run).intent_id, amount(run), outcome)
                           nil
                         }),
            I::Phase.new(from: 'capture_recorded', to: I::FINISHED, atomic: lambda { |run, db, _|
              render_intent(run, db, input(run).intent_id)
            })
          ]
        end

        sig { override.params(run: I::Run, db: Sequel::Database).void }
        def release(run, db)
          IntentLock.release(db, input(run).intent_id, run.key_id)
        end

        private

        sig { params(run: I::Run).returns(Capture::Input) }
        def input(run) = T.cast(run.input, Capture::Input)

        sig { params(run: I::Run).returns(PaymentIntent) }
        def intent(run)
          PaymentIntents.find!(ctx(run).db, merchant_id: ctx(run).merchant!.id, id: input(run).intent_id)
        end

        sig { params(run: I::Run).returns(Money) }
        def amount(run) = Money.of(Integer(run.state.fetch('amount')), intent(run).currency)
      end

      # POST /v1/payment_intents/:id/cancel. The void only happens when there is an
      # authorization to release; otherwise its phase has no foreign step.
      #
      #   started -> intent_locked -> void_requested -> canceled -> finished
      class CancelIntent < Base
        sig { override.returns(String) }
        def name = 'payment_intent.cancel'

        sig { override.params(hash: T::Hash[String, T.untyped]).returns(Cancel::Input) }
        def load_input(hash) = Cancel::Input.from_hash(hash)

        sig { override.returns(T::Array[I::Phase]) }
        def phases
          [
            I::Phase.new(from: I::STARTED, to: 'intent_locked', atomic: lambda { |run, db, _|
              intent = Cancel.check!(db, ctx(run), input(run))
              IntentLock.take!(db, intent.id, run.key_id)
              run.state['void'] = Cancel.needs_void?(intent)
              nil
            }),
            checkpoint('intent_locked', 'void_requested'),
            I::Phase.new(from: 'void_requested', to: 'canceled',
                         foreign: lambda { |run|
                           next nil unless run.state['void']

                           Flows.definite(run, send: -> { Cancel.void(ctx(run), intent(run)) },
                                               look_up: -> { Cancel.look_up(ctx(run), intent(run)) })
                         },
                         atomic: lambda { |run, db, _|
                           Cancel.record!(db, ctx(run), input(run))
                           nil
                         }),
            I::Phase.new(from: 'canceled', to: I::FINISHED, atomic: lambda { |run, db, _|
              render_intent(run, db, input(run).intent_id)
            })
          ]
        end

        sig { override.params(run: I::Run, db: Sequel::Database).void }
        def release(run, db)
          IntentLock.release(db, input(run).intent_id, run.key_id)
        end

        private

        sig { params(run: I::Run).returns(Cancel::Input) }
        def input(run) = T.cast(run.input, Cancel::Input)

        sig { params(run: I::Run).returns(PaymentIntent) }
        def intent(run)
          PaymentIntents.find!(ctx(run).db, merchant_id: ctx(run).merchant!.id, id: input(run).intent_id)
        end
      end

      # POST /v1/refunds. The refund id, created in the first phase, is the
      # acquirer key and travels in the key's state.
      #
      #   started -> refund_created -> refund_requested -> refund_recorded -> finished
      class CreateRefund < Base
        sig { override.returns(String) }
        def name = 'refund.create'

        sig { override.params(hash: T::Hash[String, T.untyped]).returns(Refunds::Input) }
        def load_input(hash) = Refunds::Input.from_hash(hash)

        sig { override.returns(T::Array[I::Phase]) }
        def phases
          [
            I::Phase.new(from: I::STARTED, to: 'refund_created', atomic: lambda { |run, db, _|
              run.state['refund_id'] = Refunds.reserve!(db, ctx(run), T.cast(run.input, Refunds::Input)).id
              nil
            }),
            checkpoint('refund_created', 'refund_requested'),
            I::Phase.new(from: 'refund_requested', to: 'refund_recorded',
                         foreign: lambda { |run|
                           Flows.definite(run, send: -> { Refunds.request(ctx(run), refund(run)) },
                                               look_up: -> { Refunds.look_up(ctx(run), refund(run)) })
                         },
                         atomic: lambda { |run, db, outcome|
                           Refunds.record!(db, ctx(run), refund(run).id, outcome)
                           nil
                         }),
            I::Phase.new(from: 'refund_recorded', to: I::FINISHED, atomic: lambda { |run, db, _|
              run.render(Refunds.to_api(db, ctx(run), Refunds.find!(db, ctx(run), refund(run).id)))
            })
          ]
        end

        private

        sig { params(run: I::Run).returns(Refund) }
        def refund(run)
          Refunds.find!(ctx(run).db, ctx(run), String(run.state.fetch('refund_id')))
        end
      end

      CREATE_INTENT = CreateIntent.new
      CONFIRM_INTENT = ConfirmIntent.new
      CAPTURE_INTENT = CaptureIntent.new
      CANCEL_INTENT = CancelIntent.new
      CREATE_REFUND = CreateRefund.new

      # Every flow payments owns. Other areas register theirs with `register`.
      sig { returns(I::Registry) }
      def self.registry
        @registry ||= T.let(
          I::Registry.new([CREATE_INTENT, CONFIRM_INTENT, CAPTURE_INTENT, CANCEL_INTENT, CREATE_REFUND]),
          T.nilable(I::Registry)
        )
      end
    end
  end
end
