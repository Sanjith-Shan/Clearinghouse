# Experiment 1: retry storm (smoke)

| impl | intents | K | drop rate | requests | HTTP attempts | double charges | extra charges | charged, not in ledger | stuck processing | ledger captures per intent | identical bodies | truthful answers | ledger invariants | wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| none | 20 | 8 | 0.2 | 160 | 165 | 0 | 0 | 5 | 5 | 0: 5, 1: 15 | 0.25 | 0.0938 | hold | 6.471 |
| naive | 20 | 8 | 0.2 | 160 | 165 | 0 | 0 | 5 | 5 | 0: 5, 1: 15 | 0.25 | 0.0938 | hold | 5.982 |
| clearinghouse | 20 | 8 | 0.2 | 160 | 636 | 0 | 0 | 0 | 0 | 1: 20 | 1.0 | 1.0 | hold | 29.408 |

- Command: `bin/storm --impl all --intents 20 --concurrency 8 --drop-rate 0.2 --seed 1 --db clearinghouse_exp1 --label smoke --baseline-on-unknown hold`
- Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker
- Load (uptime) before: `18:12  up 1 day,  3:38, 9 users, load averages: 51.11 64.77 58.45`
- Load (uptime) after: `18:12  up 1 day,  3:39, 9 users, load averages: 49.61 62.15 57.83`
- Server: Puma, 16 threads, DB pool 16; baselines on an unknown acquirer answer: hold
- Simulator: drop_after_commit_rate 0.2, seed 1, latency p50/p99 0/0 ms
- Clients: ClearinghouseClient, max 10 retries, 4 intents stormed at a time
- Started 2026-09-24T01:12:04Z
