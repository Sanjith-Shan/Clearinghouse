# Experiment 4: ledger-seed1-n300-l80

`bin/model-test --sut ledger --sequences 300 --max-length 80 --seed 1`

Machine: Apple M3 Pro, Darwin 25.5.0, Ruby 3.3.12, PostgreSQL 16.15 in Docker,
database `clearinghouse_test_model`, pool size 2. Elapsed 375.4s.

**130 sequences, 7660 operations,
FAILED check `exception`.**

Shrunk from 56 to 5 steps; replay with `ledger-seed1-n300-l80-repro.rb`.

## Outcomes (expected by the model)

| operation and outcome | count |
|---|---|
| advance_clock ok | 941 |
| availability_sweep ok | 583 |
| cancel ok | 170 |
| cancel payment_intent_unexpected_state | 120 |
| capture amount_too_small | 4 |
| capture ok | 195 |
| capture parameter_invalid | 27 |
| capture payment_intent_unexpected_state | 153 |
| confirm card_declined | 145 |
| confirm expired_card | 99 |
| confirm ok | 780 |
| confirm payment_intent_unexpected_state | 133 |
| confirm resource_missing | 176 |
| create_intent amount_too_small | 45 |
| create_intent ok | 1571 |
| create_merchant ok | 268 |
| payout balance_insufficient | 626 |
| payout ok | 74 |
| refund charge_already_refunded | 208 |
| refund charge_disputed | 16 |
| refund ok | 540 |
| refund parameter_invalid | 78 |
| resolve_dispute dispute_already_closed | 5 |
| resolve_dispute dispute_not_open | 65 |
| resolve_dispute ok | 18 |
| settle ok | 620 |

## Money events posted

| Ledger::Flows event | count |
|---|---|
| capture | 687 |
| dispute_debited | 9 |
| dispute_funds_returned | 1 |
| dispute_opened | 32 |
| dispute_won | 8 |
| funds_available | 285 |
| payout | 74 |
| payout_failed | 5 |
| payout_paid | 42 |
| refund | 540 |
| refund_settled | 246 |
| settlement | 321 |
