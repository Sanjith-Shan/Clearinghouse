# Experiment 3 results

- Command: `bin/exp-isolation --threads 2,8,32 --trials 5 --ops 2000 --db clearinghouse_exp3 --out results/exp3-isolation/20260925T193616Z-quiet`
- Machine: Apple M3 Pro, 12 cores, 18 GB. PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2) in Docker, ruby 3.3.12.
- Pool size: equal to the thread count. 2000 operations per trial, 5 trials (seeds) per row.
- Trials run under high load (1-minute load average above 12 (the core count) before or after the trial): 0 of 60.
  Per-trial load averages are in results.json.

| strategy | threads | trials | ops/s mean (min-max) | p50 ms | p99 ms | retries /100 ops | exhausted | trials with anomalies | over-refunds (cents) | lost updates | payout double-spends | balance drift cents |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rc_read_then_write | 2 | 5 | 1262.7 (1175.7-1297.2) | 1.64 | 2.78 | 0.0 | 0 | 5/5 | 370 (2656000) | 6269 | 2 | 2133500 |
| rc_for_update | 2 | 5 | 1087.8 (1062.8-1102.9) | 1.82 | 3.28 | 0.0 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 2 | 5 | 671.2 (401.3-823.7) | 1.54 | 30.28 | 27.43 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 2 | 5 | 603.7 (547.2-656.3) | 1.66 | 48.84 | 18.67 | 16 | 0/5 | 0 (0) | 0 | 0 | 0 |
| rc_read_then_write | 8 | 5 | 1082.1 (993.6-1129.8) | 5.81 | 30.68 | 0.0 | 0 | 5/5 | 116 (5646000) | 13565 | 37 | 5489500 |
| rc_for_update | 8 | 5 | 867.9 (669.1-955.7) | 6.11 | 33.51 | 0.0 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 8 | 5 | 667.6 (644.2-699.4) | 4.61 | 64.42 | 139.28 | 3 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 8 | 5 | 661.5 (607.0-711.9) | 2.05 | 163.03 | 105.09 | 138 | 0/5 | 0 (0) | 0 | 0 | 0 |
| rc_read_then_write | 32 | 5 | 1136.5 (1091.1-1168.8) | 12.38 | 147.05 | 0.0 | 0 | 5/5 | 59 (6366000) | 15656 | 383 | 14793500 |
| rc_for_update | 32 | 5 | 1390.4 (1323.5-1460.7) | 11.45 | 73.47 | 0.0 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 32 | 5 | 253.4 (211.1-342.2) | 115.28 | 360.49 | 421.86 | 143 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 32 | 5 | 178.9 (146.3-206.4) | 66.41 | 400.86 | 445.04 | 2790 | 0/5 | 0 (0) | 0 | 0 | 0 |
