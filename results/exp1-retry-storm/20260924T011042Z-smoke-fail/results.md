# Experiment 1: retry storm (smoke)

| impl | intents | K | drop rate | requests | HTTP attempts | double charges | extra charges | charged, not in ledger | stuck processing | ledger captures per intent | identical bodies | truthful answers | ledger invariants | wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| none | 20 | 8 | 0.2 | 160 | 167 | 5 | 5 | 7 | 2 | 0: 2, 1: 18 | 0.1 | 0.1125 | hold | 11.676 |
| naive | 20 | 8 | 0.2 | 160 | 166 | 2 | 2 | 6 | 1 | 0: 4, 1: 16 | 0.2 | 0.1 | hold | 5.59 |
| clearinghouse | 20 | 8 | 0.2 | 160 | 525 | 0 | 0 | 0 | 0 | 1: 20 | 1.0 | 1.0 | hold | 17.498 |

- Command: `bin/storm --impl all --intents 20 --concurrency 8 --drop-rate 0.2 --seed 1 --db clearinghouse_exp1 --label smoke`
- Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker
- Load (uptime) before: `18:10  up 1 day,  3:37, 9 users, load averages: 55.75 69.47 59.47`
- Load (uptime) after: `18:11  up 1 day,  3:38, 9 users, load averages: 50.18 65.80 58.61`
- Server: Puma, 16 threads, DB pool 16; baselines on an unknown acquirer answer: fail
- Simulator: drop_after_commit_rate 0.2, seed 1, latency p50/p99 0/0 ms
- Clients: ClearinghouseClient, max 10 retries, 4 intents stormed at a time
- Started 2026-09-24T01:10:57Z
