# A payment smaller than the acquirer's fee could never be settled

**What broke.** `Ledger::Flows.settlement` booked the cash received as a debit of
`gross - acquirer_fee`. The simulator's acquirer fee is 1.5% plus 10 minor units of the
payment's currency, so for a payment of a few yen or a few fils the fee is larger than the
payment and the acquirer takes money from us instead of paying it. The builder produced a
debit of -9 fils to `platform:cash`, and `Ledger.post!` refused it (`InvalidPostingError:
entry amounts must be positive`). The settlement line for that payment could never be
booked, so its capture would sit in `processor_receivable` forever.

Such payments are accepted: payments requires only that *our* fee not exceed the amount,
and with no fixed fee in JPY or KWD, a 1 yen or 1 fils payment passes that check. The
simulator captures it and puts it in a settlement file with `amount 1, fee 10`.

**Caught by.** Experiment 4. `bin/model-test --sut ledger --sequences 300 --max-length 80
--seed 1` failed on sequence 130 at step 56 and shrank it in 141 runs to:

```ruby
h.create_merchant(merchant: "m1", fee_rate_scaled: 290000, fee_fixed: {"usd"=>30})
h.create_intent(intent: "pi_5", merchant: "m1", amount: 1, currency: "kwd", capture_method: "automatic")
h.confirm(intent: "pi_5", payment_method: "pm_card_visa")
h.advance_clock(hours: 48)
h.settle
# step 5 failed check exception:
#   Clearinghouse::Ledger::InvalidPostingError: entry amounts must be positive, got -0.009 KWD on platform:cash
```

The same run had passed before the model adopted payments' fee rule, because the model's
earlier minimum charge (200 fils) kept such payments out. The reference model books signed
amounts, so it expected cash to go down by 9 fils and was right. The run's files are
`results/exp4-model/ledger-seed1-n300-l80.*`.

**Fix.** `Flows.settlement` credits cash for the difference when the fee exceeds the gross
(and leaves the cash line out when they are equal), in 8e5a49a on branch
`pr/model-settlement-fee-over-gross`. Regression tests: `spec/ledger/flows_spec.rb`
("settles a capture smaller than the acquirer fee by crediting cash for the difference")
and the shrunk sequence itself in `spec/model/ledger_sut_spec.rb`.

**Still open.** Whether such tiny payments should be accepted at all is a payments policy
question (the platform loses money on each one). The reconciler, when it lands, must post
this builder rather than computing cash itself.
