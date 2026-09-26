# Experiment 1: retry storm (full)

| impl | intents | K | drop rate | requests | HTTP attempts | double charges | extra charges | charged, not in ledger | stuck processing | ledger captures per intent | identical bodies | truthful answers | ledger invariants | wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| none | 1000 | 16 | 0.1 | 16000 | 16099 | 0 | 0 | 99 | 99 | 0: 99, 1: 901 | 0.099 | 0.0563 | hold | 112.011 |
| naive | 1000 | 16 | 0.1 | 16000 | 16106 | 0 | 0 | 106 | 106 | 0: 106, 1: 894 | 0.106 | 0.0569 | hold | 88.028 |
| clearinghouse | 1000 | 16 | 0.1 | 16000 | 33828 | 0 | 0 | 0 | 0 | 1: 1000 | 1.0 | 1.0 | hold | 237.474 |

- Command: `bin/storm --impl all --intents 1000 --concurrency 16 --drop-rate 0.1 --seed 1 --label full --baseline-on-unknown hold --db clearinghouse_exp1`
- Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker
- Load (uptime) before: `19:00  up  3:10, 9 users, load averages: 31.03 28.24 22.31`
- Load (uptime) after: `19:08  up  3:18, 9 users, load averages: 35.43 39.35 31.43`
- Server: Puma, 16 threads, DB pool 16; baselines on an unknown acquirer answer: hold
- Simulator: drop_after_commit_rate 0.1, seed 1, latency p50/p99 0/0 ms
- Clients: ClearinghouseClient, max 10 retries, 4 intents stormed at a time
- Started 2026-09-25T02:00:46Z
