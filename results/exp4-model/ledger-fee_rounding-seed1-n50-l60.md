# Experiment 4: ledger-fee_rounding-seed1-n50-l60

`bin/model-test --sut ledger --sequences 50 --max-length 60 --seed 1 --plant fee_rounding`

Machine: Apple M3 Pro, Darwin 25.5.0, Ruby 3.3.12, PostgreSQL 16.15 in Docker,
database `clearinghouse_test_model`, pool size 2. Elapsed 139.6s.

**12 sequences, 576 operations,
FAILED check `balances`.**

Shrunk from 47 to 3 steps; replay with `ledger-fee_rounding-seed1-n50-l60-repro.rb`.

## Outcomes (expected by the model)

| operation and outcome | count |
|---|---|
| advance_clock ok | 65 |
| availability_sweep ok | 27 |
| cancel ok | 16 |
| cancel payment_intent_unexpected_state | 8 |
| capture ok | 14 |
| capture parameter_invalid | 3 |
| capture payment_intent_unexpected_state | 13 |
| confirm card_declined | 16 |
| confirm expired_card | 3 |
| confirm ok | 47 |
| confirm payment_intent_unexpected_state | 9 |
| confirm resource_missing | 20 |
| create_intent amount_too_small | 7 |
| create_intent ok | 115 |
| create_merchant ok | 23 |
| payout balance_insufficient | 48 |
| payout ok | 6 |
| refund charge_already_refunded | 30 |
| refund charge_disputed | 2 |
| refund ok | 44 |
| refund parameter_invalid | 4 |
| resolve_dispute dispute_not_open | 2 |
| resolve_dispute ok | 1 |
| settle ok | 53 |

## Money events posted

| Ledger::Flows event | count |
|---|---|
| capture | 41 |
| dispute_debited | 1 |
| dispute_opened | 1 |
| dispute_won | 1 |
| funds_available | 11 |
| payout | 6 |
| payout_paid | 2 |
| refund | 44 |
| refund_settled | 9 |
| settlement | 10 |
