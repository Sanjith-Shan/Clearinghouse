# Reproduces a model-based test failure (sequence seed 1000014), shrunk to
# 3 steps.
#
# step 3 (h.confirm(intent: "pi_6", payment_method: "pm_card_visa")) failed check balances:
#   merchant:m1:pending (usd): model 456, system 455, off by -1
#   platform:fee_revenue (usd): model 44, system 45, off by 1
#
# Run from the repository root:
#   CLEARINGHOUSE_DB=clearinghouse_test bundle exec ruby path/to/this_file.rb
require File.expand_path('lib/clearinghouse/testing/model', Dir.pwd)

Clearinghouse::Testing::Model::Harness.replay(sut: :ledger, plant: :fee_rounding) do |h|
  h.create_merchant(merchant: "m1", fee_rate_scaled: 290000, fee_fixed: {"usd"=>30})
  h.create_intent(intent: "pi_6", merchant: "m1", amount: 500, currency: "usd", capture_method: "automatic")
  h.confirm(intent: "pi_6", payment_method: "pm_card_visa")
end
