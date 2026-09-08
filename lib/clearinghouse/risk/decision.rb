# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Risk
    # What confirm does with RiskGate's answer. The whole policy is this table:
    #
    #   allow        proceed
    #   review       proceed, and hold the merchant's payout of these funds
    #   block        fail the intent with risk_error / payment_blocked; nothing is
    #                posted to the ledger and nothing is sent to the acquirer
    #   unavailable  proceed unchecked (fail open), recorded as risk_unavailable
    #
    # See docs/design/risk-integration.md for why unavailable proceeds and why
    # review holds the payout rather than the payment.
    module Decision
      extend T::Sig

      UNAVAILABLE = 'risk_unavailable'

      # Whether confirm goes on to the acquirer.
      class Action < T::Enum
        enums do
          Proceed = new('proceed')
          Block = new('block')
        end
      end

      # The policy's verdict on one attempt.
      class Verdict < T::Struct
        extend T::Sig

        const :action, Action
        # The PaymentIntent's `risk` column, exactly as it is to be stored.
        const :risk, T::Hash[String, T.untyped]
        # True for review: open a payout hold on the funds once they are captured.
        const :hold, T::Boolean
        # Set for Block: the error the intent fails with.
        const :error, T.nilable(Api::Errors::RiskError), default: nil

        sig { returns(T::Boolean) }
        def proceed?
          action == Action::Proceed
        end

        # Whether RiskGate looked at this payment at all.
        sig { returns(T::Boolean) }
        def checked?
          risk['decision'] != UNAVAILABLE
        end
      end

      sig { params(result: Result).returns(Verdict) }
      def self.apply(result)
        case result
        when Unavailable
          Verdict.new(action: Action::Proceed, hold: false,
                      risk: { 'decision' => UNAVAILABLE, 'reason' => result.reason.serialize })
        when Assessment then from_assessment(result)
        else T.absurd(result)
        end
      end

      sig { params(assessment: Assessment).returns(Verdict) }
      def self.from_assessment(assessment)
        risk = { 'decision' => assessment.decision, 'score' => assessment.risk_score,
                 'reasons' => assessment.reasons, 'assessment_id' => assessment.assessment_id,
                 'ruleset_version' => assessment.ruleset_version }
        case assessment.decision
        when 'allow' then Verdict.new(action: Action::Proceed, hold: false, risk: risk)
        when 'review' then Verdict.new(action: Action::Proceed, hold: true, risk: risk)
        when 'block' then Verdict.new(action: Action::Block, hold: false, risk: risk, error: Api::Errors::RiskError.new)
        else
          # Assessment.from_json admits only the three decisions above.
          raise ArgumentError, "unknown decision #{assessment.decision}"
        end
      end
      private_class_method :from_assessment
    end
  end
end
