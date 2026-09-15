# Experiment 4: ledger-payout_failed_skips_clearing-seed1-n100-l60

`bin/model-test --sut ledger --sequences 100 --max-length 60 --seed 1 --plant payout_failed_skips_clearing`

Machine: Apple M3 Pro, Darwin 25.5.0, Ruby 3.3.12, PostgreSQL 16.15 in Docker,
database `clearinghouse_test_model`, pool size 2. Elapsed 99.9s.

**31 sequences, 1370 operations,
FAILED check `balances`.**

Shrunk from 45 to 7 steps; replay with `ledger-payout_failed_skips_clearing-seed1-n100-l60-repro.rb`.

## Outcomes (expected by the model)

| operation and outcome | count |
|---|---|
| advance_clock ok | 176 |
| availability_sweep ok | 105 |
| cancel ok | 29 |
| cancel payment_intent_unexpected_state | 26 |
| capture amount_too_large | 2 |
| capture ok | 35 |
| capture payment_intent_unexpected_state | 28 |
| confirm card_declined | 36 |
| confirm ok | 130 |
| confirm payment_intent_unexpected_state | 17 |
| confirm resource_missing | 33 |
| create_intent amount_too_small | 31 |
| create_intent ok | 256 |
| create_merchant ok | 58 |
| payout balance_insufficient | 120 |
| payout ok | 14 |
| refund amount_too_large | 6 |
| refund charge_already_refunded | 40 |
| refund charge_disputed | 1 |
| refund ok | 96 |
| resolve_dispute dispute_already_closed | 1 |
| resolve_dispute dispute_not_open | 11 |
| resolve_dispute ok | 4 |
| settle ok | 115 |

## Money events posted

| Ledger::Flows event | count |
|---|---|
| capture | 109 |
| dispute_debited | 1 |
| dispute_opened | 5 |
| dispute_won | 1 |
| funds_available | 31 |
| payout | 14 |
| payout_failed | 1 |
| payout_paid | 5 |
| refund | 96 |
| refund_settled | 34 |
| settlement | 30 |
