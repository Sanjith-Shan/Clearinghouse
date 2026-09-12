# Reproduces a model-based test failure (sequence seed 1000132), shrunk to
# 5 steps.
#
# step 5 (h.settle) failed check exception:
#   Clearinghouse::Ledger::InvalidPostingError: entry amounts must be positive, got -0.009 KWD on platform:cash
#   /Users/sanjithshanmugavel/Documents/Clearinghouse-wt/model/lib/clearinghouse/ledger/posting.rb:107:in `validate_entry!'
#   /Users/sanjithshanmugavel/Documents/Clearinghouse-wt/model/lib/clearinghouse/ledger/posting.rb:91:in `block in validate!'
#   /Users/sanjithshanmugavel/Documents/Clearinghouse-wt/model/lib/clearinghouse/ledger/posting.rb:90:in `each'
#   /Users/sanjithshanmugavel/Documents/Clearinghouse-wt/model/lib/clearinghouse/ledger/posting.rb:90:in `validate!'
#   /Users/sanjithshanmugavel/Documents/Clearinghouse-wt/model/lib/clearinghouse/ledger/posting.rb:27:in `post'
#   /Users/sanjithshanmugavel/Documents/Clearinghouse-wt/model/lib/clearinghouse/ledger.rb:21:in `post!'
#
# Run from the repository root:
#   CLEARINGHOUSE_DB=clearinghouse_test bundle exec ruby path/to/this_file.rb
require File.expand_path('lib/clearinghouse/testing/model', Dir.pwd)

Clearinghouse::Testing::Model::Harness.replay(sut: :ledger, plant: nil) do |h|
  h.create_merchant(merchant: "m1", fee_rate_scaled: 290000, fee_fixed: {"usd"=>30})
  h.create_intent(intent: "pi_5", merchant: "m1", amount: 1, currency: "kwd", capture_method: "automatic")
  h.confirm(intent: "pi_5", payment_method: "pm_card_visa")
  h.advance_clock(hours: 48)
  h.settle
end
