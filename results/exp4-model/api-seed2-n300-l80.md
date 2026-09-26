# Experiment 4: api-seed2-n300-l80

`bin/model-test --sut api --sequences 300 --max-length 80 --seed 2`

Machine: Apple M3 Pro, Darwin 25.5.0, Ruby 3.3.12, PostgreSQL 16.15 in Docker,
database `clearinghouse_test_model`, pool size 4. Elapsed 555.0s.

**300 sequences, 18091 operations,
every check passed after every step.**

## Outcomes (expected by the model)

| operation and outcome | count |
|---|---|
| advance_clock ok | 2238 |
| availability_sweep ok | 1470 |
| cancel ok | 382 |
| cancel payment_intent_unexpected_state | 347 |
| capture amount_too_small | 13 |
| capture ok | 497 |
| capture parameter_invalid | 62 |
| capture payment_intent_unexpected_state | 297 |
| confirm card_declined | 381 |
| confirm expired_card | 195 |
| confirm ok | 1820 |
| confirm payment_intent_unexpected_state | 334 |
| confirm resource_missing | 409 |
| create_intent amount_too_small | 114 |
| create_intent ok | 3695 |
| create_merchant ok | 640 |
| payout balance_insufficient | 1293 |
| payout ok | 175 |
| refund charge_already_refunded | 512 |
| refund ok | 1270 |
| refund parameter_invalid | 229 |
| resolve_dispute dispute_already_closed | 9 |
| resolve_dispute dispute_not_open | 178 |
| resolve_dispute ok | 58 |
| settle ok | 1473 |

## Money events posted

| Ledger::Flows event | count |
|---|---|
| capture | 1612 |
| dispute_debited | 42 |
| dispute_funds_returned | 6 |
| dispute_opened | 113 |
| dispute_won | 25 |
| funds_available | 696 |
| payout | 175 |
| payout_failed | 21 |
| payout_paid | 97 |
| refund | 1236 |
| refund_settled | 508 |
| settlement | 703 |
