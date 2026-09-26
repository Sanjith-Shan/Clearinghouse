# Experiment 8 replay: policy `model_only` (full)

Command: `bin/exp-replay --replay ~/Documents/RiskGate/data/export_real/test_replay.jsonl --policy model_only --riskgate-url http://127.0.0.1:8092 --webhook-secret whsec_exp8_replay_not_a_secret --label full --db clearinghouse_test_exp3 --reset-db --out results/exp8-replay/20260925T020100Z-full-model_only`

Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker. Load average (1/5/15 min) before 32.87/38.01/31.52, after 6.84/9.04/13.27.

Replay file: ~/Documents/RiskGate/data/export_real/test_replay.jsonl (read in place; no rows are stored), 92427 rows, seed 1. Simulated time 2018-05-01T00:00:56Z to 2018-06-09T23:58:51Z; 0 rows out of time order.

RiskGate: riskgate at http://127.0.0.1:8092, ruleset 2 (seen on decisions: {"2"=>92019}), deadline 50 ms.

## Money (USD)

| | count | volume |
|---|---|---|
| payments | 92427 | |
| approved | 92043 | $12,626,377.52 |
| blocked | 384 | $100,221.48 |
| reviews | 0 | $0.00 |
| risk_unavailable | 24 | $2,384.01 |
| declined_or_error | 0 | $0.00 |
| fraud caught (is_fraud=1 blocked) | 227 | $59,862.04 |
| fraud through | 2986 | $427,600.72 |
| legitimate revenue blocked (is_fraud=0 blocked) | 157 | $40,359.44 |
| disputes (source: clearinghouse (GET /v1/disputes)) | 2986 | $427,600.72 |

Dispute losses: **$472,390.72** = disputed amount plus an **assumed** $15.00 fee per dispute.

Net of fraud checks: saved $63,267.04 (blocked fraud plus the assumed fee each would have cost) minus $40,359.44 of legitimate revenue blocked = **$22,907.60**.

## Latency

Confirm, as the client saw it: p50 39.688 ms, p99 250.462 ms (n=92427). Risk step inside it: p50 0.751 ms, p99 5.172 ms (n=92427), 0.7% of confirm time. Smoke-run latencies on a shared machine are not publishable numbers.

## The rest of the system

Review holds opened: 0 ($0.00 captured under review, $0.00 of merchant net held).
Webhooks to RiskGate: registered, workers ran: true, drained: true. charge.dispute.created {"succeeded"=>2986}; payment_intent.succeeded {"succeeded"=>92043}.
Scheduler step errors: {}. Ledger invariant violations: 0.
