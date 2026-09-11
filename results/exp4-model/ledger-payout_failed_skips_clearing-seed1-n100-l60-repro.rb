# Reproduces a model-based test failure (sequence seed 1000033), shrunk to
# 7 steps.
#
# step 7 (h.advance_clock(hours: 24)) failed check balances:
#   platform:cash (jpy): model 0, system 13, off by 13
#   platform:payout_clearing (jpy): model 0, system 13, off by 13
#
# Run from the repository root:
#   CLEARINGHOUSE_DB=clearinghouse_test bundle exec ruby path/to/this_file.rb
require File.expand_path('lib/clearinghouse/testing/model', Dir.pwd)

Clearinghouse::Testing::Model::Harness.replay(sut: :ledger, plant: :payout_failed_skips_clearing) do |h|
  h.create_merchant(merchant: "m1", fee_rate_scaled: 290000, fee_fixed: {"usd"=>30})
  h.create_intent(intent: "pi_2", merchant: "m1", amount: 50, currency: "jpy", capture_method: "automatic")
  h.confirm(intent: "pi_2", payment_method: "pm_card_visa")
  h.advance_clock(hours: 48)
  h.availability_sweep
  h.payout(payout: "po_5", merchant: "m1", currency: "jpy", amount: 13)
  h.advance_clock(hours: 24)
end
