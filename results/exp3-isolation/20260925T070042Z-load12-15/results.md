# Experiment 3 results

- Command: `bin/exp-isolation --threads 2,8,32 --trials 5 --ops 2000 --db clearinghouse_exp3 --out results/exp3-isolation/rerun`
- Machine: Apple M3 Pro, 12 cores, 18 GB. PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2) in Docker, ruby 3.3.12.
- Pool size: equal to the thread count. 2000 operations per trial, 5 trials (seeds) per row.
- Trials run under high load (1-minute load average above 12 (the core count) before or after the trial): 42 of 60.
  Per-trial load averages are in results.json.

| strategy | threads | trials | ops/s mean (min-max) | p50 ms | p99 ms | retries /100 ops | exhausted | trials with anomalies | over-refunds (cents) | lost updates | payout double-spends | balance drift cents |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rc_read_then_write | 2 | 5 | 495.8 (435.1-562.6) | 3.72 | 11.46 | 0.0 | 0 | 5/5 | 371 (2690000) | 6410 | 3 | 1879500 |
| rc_for_update | 2 | 5 | 423.3 (331.9-503.1) | 4.24 | 13.89 | 0.0 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 2 | 5 | 371.8 (350.8-397.3) | 2.88 | 52.11 | 34.82 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 2 | 5 | 340.3 (285.1-378.3) | 2.89 | 83.01 | 29.46 | 19 | 0/5 | 0 (0) | 0 | 0 | 0 |
| rc_read_then_write | 8 | 5 | 636.6 (613.1-665.5) | 9.23 | 55.83 | 0.0 | 0 | 5/5 | 121 (5584000) | 13573 | 28 | 4369000 |
| rc_for_update | 8 | 5 | 525.6 (356.8-585.7) | 10.09 | 63.24 | 0.0 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 8 | 5 | 265.3 (194.9-322.3) | 13.71 | 171.25 | 187.85 | 6 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 8 | 5 | 239.8 (195.9-284.6) | 7.38 | 252.68 | 172.81 | 386 | 0/5 | 0 (0) | 0 | 0 | 0 |
| rc_read_then_write | 32 | 5 | 321.0 (213.4-448.6) | 39.54 | 762.13 | 0.0 | 0 | 5/5 | 57 (6396000) | 15638 | 367 | 13772500 |
| rc_for_update | 32 | 5 | 417.4 (308.3-491.7) | 41.03 | 392.53 | 0.0 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 32 | 5 | 124.0 (104.5-138.3) | 202.57 | 759.51 | 486.76 | 1327 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 32 | 5 | 94.1 (86.2-99.1) | 151.76 | 831.11 | 490.01 | 3596 | 0/5 | 0 (0) | 0 | 0 | 0 |
