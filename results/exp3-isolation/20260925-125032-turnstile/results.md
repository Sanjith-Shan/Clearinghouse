# Experiment 3 results

- Command: `bin/exp-isolation --threads 8,32 --trials 2 --ops 1000 --db clearinghouse_exp3 --out results/exp3-isolation/20260925-125032-turnstile`
- Machine: Apple M3 Pro, 12 cores, 18 GB. PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2) in Docker, ruby 3.3.12.
- Pool size: equal to the thread count. 1000 operations per trial, 2 trials (seeds) per row.
- Trials run under high load (1-minute load average above 12 (the core count) before or after the trial): 0 of 24.
  Per-trial load averages are in results.json.

| strategy | threads | trials | ops/s mean (min-max) | p50 ms | p99 ms | retries /100 ops | exhausted | trials with anomalies | over-refunds (cents) | lost updates | payout double-spends | balance drift cents |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rc_read_then_write | 8 | 2 | 1303.7 (1273.8-1333.5) | 4.8 | 22.87 | 0.0 | 0 | 2/2 | 25 (1109000) | 2686 | 9 | 939000 |
| rc_for_update | 8 | 2 | 1258.9 (1228.1-1289.7) | 4.13 | 18.86 | 0.0 | 0 | 0/2 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 8 | 2 | 652.3 (643.3-661.3) | 5.01 | 64.32 | 138.75 | 0 | 0/2 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 8 | 2 | 716.3 (708.4-724.3) | 1.9 | 158.29 | 102.35 | 28 | 0/2 | 0 (0) | 0 | 0 | 0 |
| serializable_turnstile | 8 | 2 | 634.4 (619.1-649.6) | 5.96 | 108.71 | 60.05 | 1 | 0/2 | 0 (0) | 0 | 0 | 0 |
| rc_for_update_turnstile | 8 | 2 | 974.7 (927.9-1021.5) | 7.82 | 21.85 | 0.0 | 0 | 0/2 | 0 (0) | 0 | 0 | 0 |
| rc_read_then_write | 32 | 2 | 1074.4 (1016.6-1132.1) | 14.05 | 141.86 | 0.0 | 0 | 2/2 | 11 (1295000) | 3148 | 86 | 3661000 |
| rc_for_update | 32 | 2 | 1240.0 (1227.0-1252.9) | 14.18 | 84.96 | 0.0 | 0 | 0/2 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 32 | 2 | 296.4 (254.6-338.1) | 94.83 | 337.29 | 400.3 | 34 | 0/2 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 32 | 2 | 288.6 (274.7-302.5) | 36.67 | 276.31 | 401.65 | 425 | 0/2 | 0 (0) | 0 | 0 | 0 |
| serializable_turnstile | 32 | 2 | 633.8 (630.1-637.4) | 13.51 | 503.7 | 86.9 | 3 | 0/2 | 0 (0) | 0 | 0 | 0 |
| rc_for_update_turnstile | 32 | 2 | 1161.3 (1070.0-1252.5) | 22.19 | 91.25 | 0.0 | 0 | 0/2 | 0 (0) | 0 | 0 | 0 |
