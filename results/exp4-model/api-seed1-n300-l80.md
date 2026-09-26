# Experiment 4: api-seed1-n300-l80

`bin/model-test --sut api --sequences 300 --max-length 80 --seed 1`

Machine: Apple M3 Pro, Darwin 25.5.0, Ruby 3.3.12, PostgreSQL 16.15 in Docker,
database `clearinghouse_test_model`, pool size 4. Elapsed 1661.9s.

**300 sequences, 17826 operations,
every check passed after every step.**

## Outcomes (expected by the model)

| operation and outcome | count |
|---|---|
| advance_clock ok | 2164 |
| availability_sweep ok | 1406 |
| cancel ok | 378 |
| cancel payment_intent_unexpected_state | 321 |
| capture amount_too_small | 6 |
| capture ok | 500 |
| capture parameter_invalid | 70 |
| capture payment_intent_unexpected_state | 356 |
| confirm card_declined | 421 |
| confirm expired_card | 187 |
| confirm ok | 1850 |
| confirm payment_intent_unexpected_state | 291 |
| confirm resource_missing | 370 |
| create_intent amount_too_small | 95 |
| create_intent ok | 3604 |
| create_merchant ok | 631 |
| payout balance_insufficient | 1313 |
| payout ok | 180 |
| refund charge_already_refunded | 549 |
| refund ok | 1271 |
| refund parameter_invalid | 188 |
| resolve_dispute dispute_already_closed | 9 |
| resolve_dispute dispute_not_open | 149 |
| resolve_dispute ok | 46 |
| settle ok | 1471 |

## Money events posted

| Ledger::Flows event | count |
|---|---|
| capture | 1631 |
| dispute_debited | 23 |
| dispute_funds_returned | 6 |
| dispute_opened | 97 |
| dispute_won | 21 |
| funds_available | 742 |
| payout | 180 |
| payout_failed | 20 |
| payout_paid | 82 |
| refund | 1254 |
| refund_settled | 561 |
| settlement | 728 |
