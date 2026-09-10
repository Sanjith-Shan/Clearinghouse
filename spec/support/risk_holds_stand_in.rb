# typed: false
# frozen_string_literal: true

# Stands in for the payouts area's Balances::Holds until it lands on main: records
# every hold it is asked to open. Replace with the real one then.
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
