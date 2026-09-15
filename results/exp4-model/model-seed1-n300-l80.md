# Experiment 4: model-seed1-n300-l80

`bin/model-test --sut model --sequences 300 --max-length 80 --seed 1`

Machine: Apple M3 Pro, Darwin 25.5.0, Ruby 3.3.12, PostgreSQL 16.15 in Docker,
database `clearinghouse_test_model`, pool size 2. Elapsed 30.1s.

**300 sequences, 17826 operations,
every check passed after every step.**

## Outcomes (expected by the model)

| operation and outcome | count |
|---|---|
| advance_clock ok | 2190 |
| availability_sweep ok | 1416 |
| cancel ok | 390 |
| cancel payment_intent_unexpected_state | 329 |
| capture amount_too_small | 10 |
| capture ok | 493 |
| capture parameter_invalid | 71 |
| capture payment_intent_unexpected_state | 330 |
| confirm card_declined | 338 |
| confirm expired_card | 212 |
| confirm ok | 1854 |
| confirm payment_intent_unexpected_state | 300 |
| confirm resource_missing | 392 |
| create_intent amount_too_small | 99 |
| create_intent ok | 3600 |
| create_merchant ok | 626 |
| payout balance_insufficient | 1366 |
| payout ok | 170 |
| refund charge_already_refunded | 461 |
| refund charge_disputed | 46 |
| refund ok | 1280 |
| refund parameter_invalid | 199 |
| resolve_dispute dispute_already_closed | 9 |
| resolve_dispute dispute_not_open | 149 |
| resolve_dispute ok | 41 |
| settle ok | 1455 |

## Money events posted

| Ledger::Flows event | count |
|---|---|
| capture | 1636 |
| dispute_debited | 19 |
| dispute_funds_returned | 4 |
| dispute_opened | 83 |
| dispute_won | 23 |
| funds_available | 703 |
| payout | 170 |
| payout_failed | 11 |
| payout_paid | 90 |
| refund | 1280 |
| refund_settled | 582 |
| settlement | 779 |
