# Experiment 8 replay: policy `model_rules` (smoke)

Command: `bin/exp-replay --replay ~/Documents/RiskGate/data/export_synthetic/test_replay.jsonl --policy model_rules --limit 50 --fake-riskgate sim/experiments/replay/fake_policy.json --db clearinghouse_test_loadgen --reset-db --label smoke --out results/exp8-replay/20260924T200001Z-smoke`

Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker. Load average (1/5/15 min) before 10.21/11.68/15.38, after 10.21/11.68/15.38.

Replay file: ~/Documents/RiskGate/data/export_synthetic/test_replay.jsonl (read in place; no rows are stored), 50 rows, seed 1. Simulated time 2018-05-01T00:01:21Z to 2018-05-09T00:27:59Z; 0 rows out of time order.

RiskGate: fake-riskgate at http://127.0.0.1:50168, ruleset fake-exp8-smoke (seen on decisions: {"fake-exp8-smoke"=>49}), deadline 50 ms.

## Money (USD)

| | count | volume |
|---|---|---|
| payments | 50 | |
| approved | 49 | $3,295.17 |
| blocked | 1 | $422.75 |
| reviews | 2 | $698.76 |
| risk_unavailable | 0 | $0.00 |
| declined_or_error | 0 | $0.00 |
| fraud caught (is_fraud=1 blocked) | 0 | $0.00 |
| fraud through | 2 | $28.17 |
| legitimate revenue blocked (is_fraud=0 blocked) | 1 | $422.75 |
| disputes (source: clearinghouse (GET /v1/disputes)) | 2 | $28.17 |

Dispute losses: **$58.17** = disputed amount plus an **assumed** $15.00 fee per dispute.

Net of fraud checks: saved $0.00 (blocked fraud plus the assumed fee each would have cost) minus $422.75 of legitimate revenue blocked = **-$422.75**.

## Latency

Confirm, as the client saw it: p50 26.36 ms, p99 88.449 ms (n=50). Risk step inside it: p50 1.606 ms, p99 12.5 ms (n=50), 6.7% of confirm time. Smoke-run latencies on a shared machine are not publishable numbers.

## The rest of the system

Review holds opened: 2 ($698.76 captured under review, $677.90 of merchant net held).
Webhooks to RiskGate: registered, workers ran: true, drained: true. charge.dispute.created {"succeeded"=>2}; payment_intent.succeeded {"succeeded"=>49}.
Scheduler step errors: {}. Ledger invariant violations: 0.
