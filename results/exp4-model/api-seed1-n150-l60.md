# Experiment 4: api-seed1-n150-l60

`bin/model-test --sut api --sequences 150 --max-length 60 --seed 1`

Machine: Apple M3 Pro, Darwin 25.5.0, Ruby 3.3.12, PostgreSQL 16.15 in Docker,
database `clearinghouse_test_model`, pool size 4. Elapsed 668.5s.

**150 sequences, 6714 operations,
every check passed after every step.**

## Outcomes (expected by the model)

| operation and outcome | count |
|---|---|
| advance_clock ok | 1141 |
| cancel ok | 198 |
| cancel payment_intent_unexpected_state | 154 |
| capture amount_too_small | 6 |
| capture ok | 216 |
| capture parameter_invalid | 28 |
| capture payment_intent_unexpected_state | 156 |
| confirm card_declined | 260 |
| confirm expired_card | 110 |
| confirm ok | 839 |
| confirm payment_intent_unexpected_state | 151 |
| confirm resource_missing | 211 |
| create_intent amount_too_small | 45 |
| create_intent ok | 1931 |
| create_merchant ok | 306 |
| refund charge_already_refunded | 241 |
| refund ok | 622 |
| refund parameter_invalid | 99 |

## Money events posted

| Ledger::Flows event | count |
|---|---|
| capture | 744 |
| refund | 622 |
