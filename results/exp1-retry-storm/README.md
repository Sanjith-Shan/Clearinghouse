# Experiment 1: retry storm

Method, the interleavings behind each baseline's failures, and how to read these tables:
`docs/design/storm.md`.

Each directory is one `bin/storm` run, holding `results.json` (everything, including
histograms and the plan) and `results.md` (the table plus command, machine, load, server
threads and DB pool). The label is in the directory name.

## Full runs (the published result)

1,000 intents, each confirmed by K = 16 clients at once with the same Idempotency-Key, while
the simulator commits and then drops 10% of its responses. Commit `2860114`, Apple M3 Pro,
12 cores, 18 GB, PostgreSQL 16.15 in Docker, Puma 16 threads, DB pool 16. Other experiments
were running on the machine at the same time (load averages below). Every number here is a
count from the acquirer's books and the ledger, so load changes only the wall time.

- `20260924T233722Z-full`: all three implementations, baselines **fail** the attempt on a lost answer.
  `bin/storm --impl all --intents 1000 --concurrency 16 --drop-rate 0.1 --seed 1 --label full --db clearinghouse_exp1`.
  1-minute load 48.8 before, 18.5 after.
- `20260925T020044Z-full`: all three, baselines **hold** the intent in processing instead.
  The same command plus `--baseline-on-unknown hold`. 1-minute load 31.0 before, 35.4 after.

| run | impl | double charges | extra charges | charged, not in ledger | stuck processing | identical bodies | truthful answers | ledger invariants |
|---|---|---:|---:|---:|---:|---:|---:|---|
| fail | none | 95 | 103 | 108 | 14 | 0.014 | 0.0616 | hold |
| fail | naive | 35 | 35 | 101 | 13 | 0.069 | 0.0582 | hold |
| fail | **clearinghouse** | **0** | 0 | **0** | 0 | 1.0 | 1.0 | hold |
| hold | none | 0 | 0 | 99 | 99 | 0.099 | 0.0563 | hold |
| hold | naive | 0 | 0 | 106 | 106 | 0.106 | 0.0569 | hold |
| hold | **clearinghouse** | **0** | 0 | **0** | 0 | 1.0 | 1.0 | hold |

Fields: `results[impl=...]` `double_charges`, `extra_charges`, `charged_not_recorded`,
`stuck_processing`, `identical_body_rate`, `truthful_answer_rate`, `ledger_invariants`.

- Clearinghouse charged each of the 1,000 cards exactly once in both runs. There was one
  ledger capture per intent, all 16,000 clients got byte-identical bodies, and every answer
  matched the acquirer. Its extra HTTP attempts (40,240 and 33,828 for 16,000 calls) are the
  409s that duplicates get while the first request holds the key.
- With no idempotency, 95 of 1,000 cards were charged more than once (87 twice, 8 three times). The naive check-then-insert
  charged 35 twice. Both left about 100 charges the ledger never recorded.
- Holding the intent instead of failing it removes the double charges and moves the damage
  elsewhere: 99 and 106 cards charged, with the intents stuck in `processing` and nothing in
  the ledger.
- The ledger invariants held in every run, the baselines included. A double charge the
  ledger never saw breaks no invariant, which is why the charges are counted at the acquirer.
- Wall time (`wall_seconds` in `results.json`) is client backoff plus a busy machine, not
  server work. The clearinghouse part of the fail run took 3,308 s because it ran during the
  busiest part of the session, while the same part of the hold run took 237 s.

## Smoke runs

20 intents × K = 8, drop rate 0.2, on a shared machine with a load average of 50 to 70:

- `20260924T011042Z-smoke-fail`: all three implementations, baselines fail the attempt on a lost answer.
- `20260924T011155Z-smoke-hold`: the two baselines, holding the intent in processing instead.
