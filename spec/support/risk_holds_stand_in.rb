# typed: false
# frozen_string_literal: true

# Records every hold it is asked to open, for unit specs of the Risk::Holds seam.
# Everything that runs the API uses the real Balances::Holds
# (Api::Dependencies#risk_holds).
class RiskHoldsStandIn
  include Clearinghouse::Risk::Holds

  Hold = Struct.new(:db, :merchant_id, :payment_intent_id, :amount, :reason, :at, keyword_init: true)

  attr_reader :holds

  def initialize
    @holds = []
  end

  def open_hold!(db, merchant_id:, payment_intent_id:, amount:, reason:, clock:)
    @holds << Hold.new(db: db, merchant_id: merchant_id, payment_intent_id: payment_intent_id, amount: amount,
                       reason: reason, at: clock.now)
  end
end
