# Experiment 3 results

- Command: `bin/exp-isolation --threads 2,8,32 --trials 5 --ops 2000 --db clearinghouse_exp3`
- Machine: Apple M3 Pro, 12 cores, 18 GB. PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2) in Docker, ruby 3.3.12.
- Pool size: equal to the thread count. 2000 operations per trial, 5 trials (seeds) per row.
- Trials run under high load (1-minute load average above 12 (the core count) before or after the trial): 58 of 60.
  Per-trial load averages are in results.json.

| strategy | threads | trials | ops/s mean (min-max) | p50 ms | p99 ms | retries /100 ops | exhausted | trials with anomalies | over-refunds (cents) | lost updates | payout double-spends | balance drift cents |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rc_read_then_write | 2 | 5 | 325.7 (109.1-770.1) | 4.79 | 105.26 | 0.0 | 0 | 5/5 | 373 (2645000) | 6282 | 2 | 2031000 |
| rc_for_update | 2 | 5 | 113.6 (67.9-210.7) | 10.04 | 129.57 | 0.0 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 2 | 5 | 52.1 (23.8-72.9) | 13.02 | 378.67 | 51.72 | 10 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 2 | 5 | 74.6 (57.7-91.1) | 9.68 | 288.24 | 50.64 | 30 | 0/5 | 0 (0) | 0 | 0 | 0 |
| rc_read_then_write | 8 | 5 | 250.6 (108.2-343.4) | 22.18 | 210.32 | 0.0 | 0 | 5/5 | 112 (5656000) | 13557 | 31 | 4982500 |
| rc_for_update | 8 | 5 | 270.1 (217.5-315.2) | 19.84 | 150.37 | 0.0 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 8 | 5 | 94.2 (72.2-134.9) | 42.49 | 437.0 | 240.96 | 74 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 8 | 5 | 59.5 (54.6-63.3) | 50.53 | 560.57 | 274.77 | 798 | 0/5 | 0 (0) | 0 | 0 | 0 |
| rc_read_then_write | 32 | 5 | 89.8 (60.1-103.7) | 147.96 | 2546.64 | 0.0 | 0 | 5/5 | 58 (6390000) | 15595 | 334 | 13727000 |
| rc_for_update | 32 | 5 | 176.5 (146.5-206.1) | 97.02 | 779.62 | 0.0 | 0 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_retry | 32 | 5 | 129.7 (61.5-192.0) | 206.52 | 993.72 | 473.36 | 1088 | 0/5 | 0 (0) | 0 | 0 | 0 |
| serializable_for_update | 32 | 5 | 99.5 (84.7-114.6) | 135.04 | 828.3 | 478.2 | 3288 | 0/5 | 0 (0) | 0 | 0 | 0 |
