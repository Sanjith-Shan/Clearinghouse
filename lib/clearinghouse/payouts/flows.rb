# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payouts
    # POST /v1/payouts and POST /v1/payouts/:id/cancel as idempotent flows, run by
    # the idempotency framework (docs/design/idempotency.md) like every other
    # mutating request. The phases are the ones in phases.rb, one atomic phase
    # each, so the payout row's own recovery point and the key's move together.
    # docs/design/payouts.md has the crash matrix.
    module Flows
      extend T::Sig

      I = Idempotency

      # POST /v1/payouts, parsed and validated by the route.
      class CreateInput < T::Struct
        const :currency, String
        const :amount, T.nilable(Integer)
        const :description, T.nilable(String)
        const :metadata, T::Hash[String, String]
      end

      # POST /v1/payouts/:id/cancel.
      class CancelInput < T::Struct
        const :payout_id, String
      end

      # started -> balance_reserved -> bank_requested -> bank_recorded -> finished,
      # which is Payouts::RECOVERY_POINTS (a spec checks they agree).
      class Create < Payments::Flows::Base
        sig { override.returns(String) }
        def name = 'payout.create'

        sig { override.params(hash: T::Hash[String, T.untyped]).returns(CreateInput) }
        def load_input(hash) = CreateInput.from_hash(hash)

        sig { override.returns(T::Array[I::Phase]) }
        def phases
          [reserve_phase,
           I::Phase.new(from: 'balance_reserved', to: 'bank_requested', atomic: lambda { |run, db, _|
             Payouts.request_bank!(db, payout_id(run), clock: ctx(run).clock)
             nil
           }),
           bank_phase,
           I::Phase.new(from: 'bank_recorded', to: I::FINISHED, atomic: lambda { |run, db, _|
             run.render(T.must(Payouts.find(db, payout_id(run))).to_api)
           })]
        end

        private

        # Checks and reserves the balance under its row lock. Payouts from one
        # balance queue on it before their transactions begin (Turnstile), so they
        # wait for each other instead of aborting each other.
        sig { returns(I::Phase) }
        def reserve_phase
          I::Phase.new(from: I::STARTED, to: 'balance_reserved',
                       atomic: lambda { |run, db, _|
                         run.state['payout_id'] = reserve!(run, db).id
                         nil
                       },
                       queue_on: lambda { |run|
                         "balance:#{Payouts.available_account(ctx(run).merchant!.id)}:#{input(run).currency}"
                       })
        end

        # A balance that can't cover the payout is the answer to this request:
        # a 400, stored against the key.
        sig { params(run: I::Run, db: Sequel::Database).returns(Payout) }
        def reserve!(run, db)
          c = ctx(run)
          i = input(run)
          Payouts.reserve!(db, merchant_id: c.merchant!.id, currency: i.currency, clock: c.clock, amount: i.amount,
                               description: i.description, metadata: i.metadata)
        rescue BalanceInsufficientError => e
          raise Api::Errors::InvalidRequestError.new(
            "Your available balance (#{e.available}) is too low for this payout. Payouts are refused while " \
            'the available balance is zero or negative.', code: 'balance_insufficient', param: 'amount'
          )
        end

        # The bank call, and its answer recorded. A resumed phase asks the bank
        # about the payout's key before sending (Payouts.call_bank). No definite
        # answer is a retryable 503 that leaves the key and the payout at
        # bank_requested. A payout that is no longer waiting on the bank (a
        # notification overtook the request, or it was canceled before the call
        # was committed to) has nothing to send.
        sig { returns(I::Phase) }
        def bank_phase
          I::Phase.new(from: 'bank_requested', to: 'bank_recorded',
                       foreign: lambda { |run|
                         payout = T.must(Payouts.find(ctx(run).db, payout_id(run)))
                         next nil unless payout.status == 'pending' && payout.recovery_point == 'bank_requested'

                         outcome = Payouts.call_bank(ctx(run).acquirer!, payout, resuming: run.resumed)
                         case outcome
                         when Acquirer::Unknown, Acquirer::Unavailable then Payments::Support.acquirer_unavailable!(outcome)
                         else outcome
                         end
                       },
                       atomic: lambda { |run, db, outcome|
                         Payouts.record_bank!(db, payout_id(run), outcome, clock: ctx(run).clock) if outcome
                         nil
                       })
        end

        sig { params(run: I::Run).returns(CreateInput) }
        def input(run) = T.cast(run.input, CreateInput)

        sig { params(run: I::Run).returns(String) }
        def payout_id(run) = String(run.state.fetch('payout_id'))
      end

      # One phase: the reversal and the status change commit together.
      class Cancel < Payments::Flows::Base
        sig { override.returns(String) }
        def name = 'payout.cancel'

        sig { override.params(hash: T::Hash[String, T.untyped]).returns(CancelInput) }
        def load_input(hash) = CancelInput.from_hash(hash)

        sig { override.returns(T::Array[I::Phase]) }
        def phases
          [I::Phase.new(from: I::STARTED, to: I::FINISHED, atomic: lambda { |run, db, _|
            run.render(cancel!(run, db).to_api)
          })]
        end

        private

        sig { params(run: I::Run, db: Sequel::Database).returns(Payout) }
        def cancel!(run, db)
          Payouts.cancel!(db, payout_id(run), merchant_id: ctx(run).merchant!.id, clock: ctx(run).clock)
        rescue NotFoundError
          raise Api::Errors::NotFoundError.resource('payout', payout_id(run))
        rescue NotCancelableError => e
          raise Api::Errors::InvalidRequestError.new("This payout cannot be canceled: #{e.message}. Only a pending " \
                                                     'payout that has not been sent to the bank can be canceled.',
                                                     code: 'payout_not_cancelable')
        end

        sig { params(run: I::Run).returns(String) }
        def payout_id(run) = T.cast(run.input, CancelInput).payout_id
      end

      CREATE = Create.new
      CANCEL = Cancel.new
      Payments::Flows.registry.register(CREATE)
      Payments::Flows.registry.register(CANCEL)
    end
  end
end
