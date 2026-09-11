# Experiment 4: ledger-fee_rounding-seed1-n50-l60

`bin/model-test --sut ledger --sequences 50 --max-length 60 --seed 1 --plant fee_rounding`

Machine: Apple M3 Pro, Darwin 25.5.0, Ruby 3.3.12, PostgreSQL 16.15 in Docker,
database `clearinghouse_test_model`, pool size 2. Elapsed 2.2s.

**3 sequences, 138 operations,
FAILED check `balances`.**

Shrunk from 25 to 3 steps; replay with `ledger-fee_rounding-seed1-n50-l60-repro.rb`.

## Outcomes (expected by the model)

| operation and outcome | count |
|---|---|
| advance_clock ok | 17 |
| availability_sweep ok | 11 |
| cancel ok | 3 |
| cancel payment_intent_unexpected_state | 3 |
| capture ok | 4 |
| capture payment_intent_unexpected_state | 2 |
| confirm card_declined | 3 |
| confirm ok | 13 |
| confirm payment_intent_unexpected_state | 1 |
| confirm resource_missing | 8 |
| create_intent amount_too_small | 6 |
| create_intent ok | 22 |
| create_merchant ok | 4 |
| payout balance_insufficient | 10 |
| payout ok | 3 |
| refund amount_too_large | 1 |
| refund charge_already_refunded | 2 |
| refund ok | 11 |
| resolve_dispute dispute_not_open | 2 |
| settle ok | 12 |

## Money events posted

| Ledger::Flows event | count |
|---|---|
| capture | 10 |
| dispute_debited | 1 |
| dispute_opened | 1 |
| funds_available | 2 |
| payout | 3 |
| refund | 11 |
| refund_settled | 5 |
| settlement | 6 |
