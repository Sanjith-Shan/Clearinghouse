# Experiment 1: retry storm (full)

| impl | intents | K | drop rate | requests | HTTP attempts | double charges | extra charges | charged, not in ledger | stuck processing | ledger captures per intent | identical bodies | truthful answers | ledger invariants | wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| none | 1000 | 16 | 0.1 | 16000 | 16117 | 95 | 103 | 108 | 14 | 0: 14, 1: 986 | 0.014 | 0.0616 | hold | 86.645 |
| naive | 1000 | 16 | 0.1 | 16000 | 16104 | 35 | 35 | 101 | 13 | 0: 69, 1: 931 | 0.069 | 0.0582 | hold | 104.522 |
| clearinghouse | 1000 | 16 | 0.1 | 16000 | 40240 | 0 | 0 | 0 | 0 | 1: 1000 | 1.0 | 1.0 | hold | 3308.122 |

- Command: `bin/storm --impl all --intents 1000 --concurrency 16 --drop-rate 0.1 --seed 1 --label full --db clearinghouse_exp1`
- Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker
- Load (uptime) before: `16:37  up 47 mins, 8 users, load averages: 48.78 73.90 65.13`
- Load (uptime) after: `17:37  up  1:47, 9 users, load averages: 18.50 25.48 33.18`
- Server: Puma, 16 threads, DB pool 16; baselines on an unknown acquirer answer: fail
- Simulator: drop_after_commit_rate 0.1, seed 1, latency p50/p99 0/0 ms
- Clients: ClearinghouseClient, max 10 retries, 4 intents stormed at a time
- Started 2026-09-24T23:37:26Z
