# typed: true
# frozen_string_literal: true

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): the request per flow.
  module CrashMatrix
    # The request a case crashes, with the preconditions its flow needs. There is
    # one scenario per flow in the registry, looked up by the flow's name; a flow
    # registered without one stops the matrix (MissingScenarioError) instead of
    # being skipped, which is how a new flow cannot go untested.
    #
    # A scenario's setup only ever uses *other* flows (confirm is set up with a
    # create, capture with a create and a confirm), so it can run on the armed
    # server without reaching the crash point it is preparing for.
    class Scenario
      extend T::Sig
      extend T::Helpers

      abstract!

      # What to send: the path and the form parameters.
      class Request < T::Struct
        const :path, String
        const :params, T::Hash[String, T.untyped]
      end

      class SetupError < StandardError; end

      sig { abstract.returns(String) }
      def flow; end

      # Creates the preconditions through the API and returns what the request
      # needs (an intent id). `tag` makes the setup's own Idempotency-Keys unique.
      sig { abstract.params(api: ApiClient, tag: String).returns(T::Hash[String, String]) }
      def setup(api, tag); end

      sig { abstract.params(state: T::Hash[String, String]).returns(Request) }
      def request(state); end

      # What a finished request should have left: the problems, empty if none.
      sig { abstract.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts); end

      # The PaymentIntent the request was about. Create learns it from the
      # response; every other flow knew it before sending.
      sig { params(state: T::Hash[String, String], reply: Reply).returns(T.nilable(String)) }
      def intent_id(state, reply)
        state['intent_id'] || reply.json['payment_intent'] || reply.json['id']
      end

      private

      sig do
        params(api: ApiClient, tag: String, capture_method: String, confirm: T::Boolean)
          .returns(T::Hash[String, String])
      end
      def intent(api, tag, capture_method: 'automatic', confirm: false)
        created = api.post('/v1/payment_intents', CREATE_PARAMS.merge('capture_method' => capture_method),
                           key: "#{tag}:setup-create")
        raise SetupError, "setup create: #{created}" unless created.status == 200

        id = created.json.fetch('id')
        if confirm
          confirmed = api.post("/v1/payment_intents/#{id}/confirm", {}, key: "#{tag}:setup-confirm")
          raise SetupError, "setup confirm: #{confirmed}" unless confirmed.status == 200
        end
        { 'intent_id' => id }
      end

      sig do
        params(facts: T::Hash[String, T.untyped], expected: T::Hash[String, T.untyped]).returns(T::Array[String])
      end
      def expect_intent(facts, expected)
        got = facts.fetch('intent').slice(*expected.keys)
        got == expected ? [] : ["intent is #{got}, expected #{expected}"]
      end
    end

    CREATE_PARAMS = T.let({ 'amount' => 2000, 'currency' => 'usd', 'payment_method' => 'pm_card_visa' }.freeze,
                          T::Hash[String, T.untyped])

    # POST /v1/payment_intents.
    class CreateScenario < Scenario
      sig { override.returns(String) }
      def flow = 'payment_intent.create'

      sig { override.params(_api: ApiClient, _tag: String).returns(T::Hash[String, String]) }
      def setup(_api, _tag) = {}

      sig { override.params(_state: T::Hash[String, String]).returns(Request) }
      def request(_state) = Request.new(path: '/v1/payment_intents', params: CREATE_PARAMS)

      sig { override.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts)
        expect_intent(facts, 'status' => 'requires_confirmation', 'amount' => 2000, 'amount_received' => 0)
      end
    end

    # POST /v1/payment_intents/:id/confirm, automatic capture: one authorization
    # that captures.
    class ConfirmScenario < Scenario
      sig { override.returns(String) }
      def flow = 'payment_intent.confirm'

      sig { override.params(api: ApiClient, tag: String).returns(T::Hash[String, String]) }
      def setup(api, tag) = intent(api, tag)

      sig { override.params(state: T::Hash[String, String]).returns(Request) }
      def request(state) = Request.new(path: "/v1/payment_intents/#{state.fetch('intent_id')}/confirm", params: {})

      sig { override.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts)
        expect_intent(facts, 'status' => 'succeeded', 'amount_received' => 2000, 'attempt' => 1, 'owned' => false)
      end
    end

    # POST /v1/payment_intents/:id/capture, partial, on a confirmed manual-capture
    # intent. Partial on purpose: the amount is fixed in the key's flow_state at
    # intent_locked, and a resume must send that amount, not the full one.
    class CaptureScenario < Scenario
      sig { override.returns(String) }
      def flow = 'payment_intent.capture'

      sig { override.params(api: ApiClient, tag: String).returns(T::Hash[String, String]) }
      def setup(api, tag) = intent(api, tag, capture_method: 'manual', confirm: true)

      sig { override.params(state: T::Hash[String, String]).returns(Request) }
      def request(state)
        Request.new(path: "/v1/payment_intents/#{state.fetch('intent_id')}/capture",
                    params: { 'amount_to_capture' => 1500 })
      end

      sig { override.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts)
        expect_intent(facts, 'status' => 'succeeded', 'amount_received' => 1500, 'amount_capturable' => 0,
                             'owned' => false)
      end
    end

    # POST /v1/payment_intents/:id/cancel on an authorized, uncaptured intent, so
    # the cancel has an authorization to void at the acquirer.
    class CancelScenario < Scenario
      sig { override.returns(String) }
      def flow = 'payment_intent.cancel'

      sig { override.params(api: ApiClient, tag: String).returns(T::Hash[String, String]) }
      def setup(api, tag) = intent(api, tag, capture_method: 'manual', confirm: true)

      sig { override.params(state: T::Hash[String, String]).returns(Request) }
      def request(state) = Request.new(path: "/v1/payment_intents/#{state.fetch('intent_id')}/cancel", params: {})

      sig { override.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts)
        voided = facts.dig('acquirer', 'authorizations')&.map { |a| a['voided'] }
        problems = expect_intent(facts, 'status' => 'canceled', 'amount_received' => 0, 'owned' => false)
        problems << "acquirer authorizations voided: #{voided.inspect}, expected [true]" unless voided == [true]
        problems
      end
    end

    # POST /v1/refunds, partial, on a succeeded intent.
    class RefundScenario < Scenario
      sig { override.returns(String) }
      def flow = 'refund.create'

      sig { override.params(api: ApiClient, tag: String).returns(T::Hash[String, String]) }
      def setup(api, tag) = intent(api, tag, confirm: true)

      sig { override.params(state: T::Hash[String, String]).returns(Request) }
      def request(state)
        Request.new(path: '/v1/refunds', params: { 'payment_intent' => state.fetch('intent_id'), 'amount' => 500 })
      end

      sig { override.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts)
        refunds = facts.fetch('refunds').map { |r| r.slice('status', 'amount') }
        problems = expect_intent(facts, 'status' => 'succeeded', 'amount_received' => 2000, 'amount_refunded' => 500)
        problems << "refunds are #{refunds}, expected one succeeded for 500" unless
          refunds == [{ 'status' => 'succeeded', 'amount' => 500 }]
        problems
      end
    end

    class MissingScenarioError < StandardError; end

    SCENARIOS = T.let(
      [CreateScenario.new, ConfirmScenario.new, CaptureScenario.new, CancelScenario.new, RefundScenario.new]
        .to_h { |s| [s.flow, s] }.freeze,
      T::Hash[String, Scenario]
    )

    sig { params(flow: String, scenarios: T::Hash[String, Scenario]).returns(Scenario) }
    def self.scenario_for(flow, scenarios = SCENARIOS)
      scenarios.fetch(flow) do
        raise MissingScenarioError,
              "flow #{flow} is registered but has no crash-matrix scenario; add one in " \
              'sim/experiments/crash_matrix/scenarios.rb so its recovery points are tested'
      end
    end
  end
end
