# Experiment 8 replay: policy `none` (smoke)

Command: `bin/exp-replay --replay ~/Documents/RiskGate/data/export_synthetic/test_replay.jsonl --policy none --limit 50 --fake-riskgate sim/experiments/replay/fake_policy.json --db clearinghouse_test_loadgen --reset-db --label smoke --out results/exp8-replay/20260924T200001Z-smoke`

Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker. Load average (1/5/15 min) before 10.23/11.71/15.42, after 10.21/11.68/15.38.

Replay file: ~/Documents/RiskGate/data/export_synthetic/test_replay.jsonl (read in place; no rows are stored), 50 rows, seed 1. Simulated time 2018-05-01T00:01:21Z to 2018-05-09T00:27:59Z; 0 rows out of time order.

RiskGate: none at -, ruleset - (seen on decisions: {}), deadline 50 ms.

## Money (USD)

| | count | volume |
|---|---|---|
| payments | 50 | |
| approved | 50 | $3,717.92 |
| blocked | 0 | $0.00 |
| reviews | 0 | $0.00 |
| risk_unavailable | 0 | $0.00 |
| declined_or_error | 0 | $0.00 |
| fraud caught (is_fraud=1 blocked) | 0 | $0.00 |
| fraud through | 2 | $28.17 |
| legitimate revenue blocked (is_fraud=0 blocked) | 0 | $0.00 |
| disputes (source: clearinghouse (GET /v1/disputes)) | 2 | $28.17 |

Dispute losses: **$58.17** = disputed amount plus an **assumed** $15.00 fee per dispute.

Net of fraud checks: saved $0.00 (blocked fraud plus the assumed fee each would have cost) minus $0.00 of legitimate revenue blocked = **$0.00**.

## Latency

Confirm, as the client saw it: p50 24.827 ms, p99 240.349 ms (n=50). Risk step inside it: p50 - ms, p99 - ms (n=0), not called. Smoke-run latencies on a shared machine are not publishable numbers.

## The rest of the system

Review holds opened: 0 ($0.00 captured under review, $0.00 of merchant net held).
Webhooks to RiskGate: not registered.
Scheduler step errors: {}. Ledger invariant violations: 0.
