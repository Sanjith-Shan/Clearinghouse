# Experiment 8 replay: policy `none` (full)

Command: `bin/exp-replay --replay ~/Documents/RiskGate/data/export_real/test_replay.jsonl --policy none --label full --db clearinghouse_test_loadgen --reset-db --out results/exp8-replay/20260925T020100Z-full-none`

Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker. Load average (1/5/15 min) before 28.26/27.76/22.28, after 11.2/15.85/17.86.

Replay file: ~/Documents/RiskGate/data/export_real/test_replay.jsonl (read in place; no rows are stored), 92427 rows, seed 1. Simulated time 2018-05-01T00:00:56Z to 2018-06-09T23:58:51Z; 0 rows out of time order.

RiskGate: none at -, ruleset - (seen on decisions: {}), deadline 50 ms.

## Money (USD)

| | count | volume |
|---|---|---|
| payments | 92427 | |
| approved | 92427 | $12,726,599.00 |
| blocked | 0 | $0.00 |
| reviews | 0 | $0.00 |
| risk_unavailable | 0 | $0.00 |
| declined_or_error | 0 | $0.00 |
| fraud caught (is_fraud=1 blocked) | 0 | $0.00 |
| fraud through | 3213 | $487,462.76 |
| legitimate revenue blocked (is_fraud=0 blocked) | 0 | $0.00 |
| disputes (source: clearinghouse (GET /v1/disputes)) | 3213 | $487,462.76 |

Dispute losses: **$535,657.76** = disputed amount plus an **assumed** $15.00 fee per dispute.

Net of fraud checks: saved $0.00 (blocked fraud plus the assumed fee each would have cost) minus $0.00 of legitimate revenue blocked = **$0.00**.

## Latency

Confirm, as the client saw it: p50 37.818 ms, p99 231.907 ms (n=92427). Risk step inside it: p50 - ms, p99 - ms (n=0), not called. Smoke-run latencies on a shared machine are not publishable numbers.

## The rest of the system

Review holds opened: 0 ($0.00 captured under review, $0.00 of merchant net held).
Webhooks to RiskGate: not registered.
Scheduler step errors: {}. Ledger invariant violations: 0.
