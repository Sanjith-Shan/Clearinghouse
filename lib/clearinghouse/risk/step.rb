# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Risk
    # The risk check as a step of confirm, between the `intent_locked` and
    # `authorization_requested` recovery points. The exact integration, which the
    # payments flow must follow, is in docs/design/risk-integration.md, "Where the
    # step sits in confirm". In short:
    #
    # 1. `intent_locked` commits (attempt incremented, status processing).
    # 2. `Step.call` runs with no database transaction open: it is a network call
    #    of up to the deadline, and holding row locks across it would stretch every
    #    confirm on a merchant by RiskGate's latency.
    # 3. The next phase's transaction stores `outcome.verdict.risk` in the intent's
    #    `risk` column. On Block, that same transaction fails the intent with
    #    `outcome.verdict.error`, posts nothing, and the acquirer is never called.
    #    On Proceed, it writes the `authorization_requested` recovery point and the
    #    flow goes on to the acquirer.
    # 4. When funds are captured, the capture transaction calls
    #    `Step.hold_on_capture!`, which opens a payout hold if the stored decision
    #    was review.
    #
    # A crash between 2 and 3 resumes at `intent_locked` and calls RiskGate again
    # with the same attempt, so the same Idempotency-Key. Correctness does not rest
    # on getting the same answer back: nothing acts on a decision until the
    # transaction that stores it commits, so whichever answer is stored is the one
    # acted on. The key's dedupe on RiskGate's side is what keeps the retry from
    # counting the payment twice in its velocity features.
    module Step
      extend T::Sig

      # What the step decided, and what it cost.
      class Outcome < T::Struct
        const :verdict, Decision::Verdict
        const :result, Result
        # Wall time the step took, for the latency budget and experiment 9.
        const :elapsed_ms, Float
        # Simulated time of the check, for logs and events.
        const :assessed_at, Time
      end

      # `intent_attrs` needs :id, :amount (minor units), :currency, :created_at and
      # optionally :risk_fields, the merchant's risk fields as stored on the intent.
      sig do
        params(intent_attrs: T::Hash[Symbol, T.untyped], attempt: Integer, clock: Clock, client: Client,
               monotonic: Monotonic).returns(Outcome)
      end
      def self.call(intent_attrs, attempt:, clock:, client: Risk.client, monotonic: Monotonic::Real.new)
        request = AssessRequest.new(
          payment_id: intent_attrs.fetch(:id),
          created: intent_attrs.fetch(:created_at).to_i,
          amount: Money.of(intent_attrs.fetch(:amount), intent_attrs.fetch(:currency)),
          risk_fields: intent_attrs.fetch(:risk_fields, nil) || {}
        )
        started = monotonic.now
        result = client.assess(request, attempt: attempt)
        Outcome.new(verdict: Decision.apply(result), result: result, elapsed_ms: (monotonic.now - started) * 1000.0,
                    assessed_at: clock.now)
      end

      # Opens the payout hold for a payment RiskGate sent to review, for the amount
      # actually captured (a partial capture holds only what moved), and returns
      # that amount. The money held is the merchant's net of it (see Holds). Does
      # nothing and returns nil for any other decision. Call it inside the
      # capture's transaction, so the funds never become payable without the hold.
      sig do
        params(db: T.untyped, risk: T.nilable(T::Hash[String, T.untyped]), merchant_id: String,
               payment_intent_id: String, amount_captured: Money, clock: Clock, holds: Holds)
          .returns(T.nilable(Money))
      end
      def self.hold_on_capture!(db, risk:, merchant_id:, payment_intent_id:, amount_captured:, clock:,
                                holds: Risk.holds)
        return nil unless risk && risk['decision'] == 'review' && amount_captured.positive?

        holds.open_hold!(db, merchant_id: merchant_id, payment_intent_id: payment_intent_id,
                             amount: amount_captured, reason: review_reason(risk), clock: clock)
        amount_captured
      end

      # What the review shows as its reason: RiskGate's reasons for sending the
      # payment to review, or the generic one when it gave none.
      sig { params(risk: T::Hash[String, T.untyped]).returns(String) }
      def self.review_reason(risk)
        reasons = Array(risk['reasons']).map(&:to_s).reject(&:empty?)
        reasons.empty? ? Holds::REASON : reasons.join('; ')
      end
    end
  end
end
