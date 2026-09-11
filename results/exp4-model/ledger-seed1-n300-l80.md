# Experiment 4: ledger-seed1-n300-l80

`bin/model-test --sut ledger --sequences 300 --max-length 80 --seed 1`

Machine: Apple M3 Pro, Darwin 25.5.0, Ruby 3.3.12, PostgreSQL 16.15 in Docker,
database `clearinghouse_test_model`, pool size 2. Elapsed 260.3s.

**300 sequences, 17826 operations,
every check passed after every step.**

## Outcomes (expected by the model)

| operation and outcome | count |
|---|---|
| advance_clock ok | 2199 |
| availability_sweep ok | 1464 |
| cancel ok | 357 |
| cancel payment_intent_unexpected_state | 376 |
| capture amount_too_large | 71 |
| capture ok | 511 |
| capture payment_intent_unexpected_state | 330 |
| confirm card_declined | 400 |
| confirm ok | 1891 |
| confirm payment_intent_unexpected_state | 298 |
| confirm resource_missing | 386 |
| create_intent amount_too_small | 342 |
| create_intent ok | 3378 |
| create_merchant ok | 616 |
| payout balance_insufficient | 1353 |
| payout ok | 173 |
| refund amount_too_large | 209 |
| refund charge_already_refunded | 479 |
| refund charge_disputed | 47 |
| refund ok | 1264 |
| resolve_dispute dispute_already_closed | 4 |
| resolve_dispute dispute_not_open | 149 |
| resolve_dispute ok | 50 |
| settle ok | 1479 |

## Money events posted

| Ledger::Flows event | count |
|---|---|
| capture | 1674 |
| dispute_debited | 40 |
| dispute_funds_returned | 9 |
| dispute_opened | 103 |
| dispute_won | 30 |
| funds_available | 744 |
| payout | 173 |
| payout_failed | 18 |
| payout_paid | 79 |
| refund | 1264 |
| refund_settled | 590 |
| settlement | 805 |
