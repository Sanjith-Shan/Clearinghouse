# Where every number comes from

Every number the README or a resume might quote: the command that produced it, the file and
field it lives in, the machine and load it was measured under, and its status. A number is
quoted from its results file, never from memory or from a smoke run.

**Machine for every row:** Apple M3 Pro, 12 cores (6 performance, 6 efficiency), 18 GB,
macOS 26.5; PostgreSQL 16.15 in Docker (container `clearinghouse-db-1`, localhost:54329);
Ruby 3.3.12. **Commit for every Clearinghouse run: `2860114`** (main on 2026-09-24), except
experiment 7's provisional report, from `7091fc6` (see its row). Experiment 2's reports say
`2860114-dirty` because the worktree held uncommitted results and doc edits, not code.

Rules that apply to every row:

- The load average travels with the number. **Timing numbers** (experiments 3 and 6) come
  only from the runs made on 2026-09-25 with nothing else heavy on the machine. Earlier runs
  under load are kept in `results/`, labelled with their load in the directory name, and are
  not quoted.
- **Count numbers** (double charges, crash points recovered, discrepancies detected, model
  checks, dollar outcomes) do not depend on load. Several of those runs shared the machine
  with other experiments, and the load is recorded next to them anyway.
- Baseline numbers (no idempotency, the naive check, the FIFO queue, READ COMMITTED
  read-then-write) are quoted only next to the careful version's number from the same run.
- Unflattering numbers are published with their explanation: the throughput cost of
  SERIALIZABLE, the duplicates under `kill -9`, and legitimate revenue blocked.
- Smoke directories say `smoke` in their name and in the JSON, and are never quoted.

| # | Number | Value | Command | Results file, field | Load (1-min) | Status |
|---|---|---|---|---|---|---|
| 1 | Double charges, no idempotency | 95 of 1,000 intents (103 extra charges) | `bin/storm --impl all --intents 1000 --concurrency 16 --drop-rate 0.1 --seed 1 --label full --db clearinghouse_exp1` | `results/exp1-retry-storm/20260924T233722Z-full/results.json`, `results[impl=none].double_charges`, `.extra_charges` | 48.8 before, 18.5 after | MEASURED |
| 1 | Double charges, naive check-then-insert | 35 of 1,000 | same run | same file, `results[impl=naive].double_charges` | same | MEASURED |
| 1 | Double charges, Clearinghouse | **0** of 1,000 | same run | same file, `results[impl=clearinghouse].double_charges` | same | MEASURED |
| 1 | Charged but not in the ledger | none 108, naive 101, Clearinghouse 0 | same run | same file, `results[*].charged_not_recorded` | same | MEASURED |
| 1 | Clients given identical and truthful answers | Clearinghouse 1.0 and 1.0; none 0.014 and 0.0616; naive 0.069 and 0.0582 | same run | same file, `results[*].identical_body_rate`, `.truthful_answer_rate` | same | MEASURED |
| 1 | The same with baselines holding the intent | double charges 0 / 0 / 0; charged not in ledger none 99, naive 106, Clearinghouse 0 | the command above plus `--baseline-on-unknown hold` | `results/exp1-retry-storm/20260925T020044Z-full/results.json`, same fields | 31.0 before, 35.4 after | MEASURED |
| 2 | Recovery points crashed at | 88 (76 in the registry's 9 request flows, 12 in 4 background flows) | `bin/crash-matrix --db clearinghouse_exp2` and `bin/crash-matrix --recovery completer --db clearinghouse_exp2` | `results/exp2-crash-matrix/20260925T022011Z-retry/report.json` and `.../20260925T022444Z-completer/report.json`, `headline`, `registry_crash_points`, `background_crash_points` | 15.1 before, 14.2 after (retry); 14.2 and 30.5 (completer) | MEASURED |
| 2 | Flows those points span | 13 | same runs | same files, `registry_flows`, `background_flows` | same | MEASURED |
| 2 | Cases recovered, and cases failed | 89 passed, **0 failed**, in each mode (88 points plus the ambiguous-acquirer variant) | same runs | same files, `passed`, `failed` | same | MEASURED |
| 3 | Anomalies per strategy | read-then-write: anomalies in 15 of 15 trials (up to 370 over-refunds, 15,656 lost updates, 383 payout double-spends, $147,935 drift per 5 trials); `rc_for_update`, `serializable_retry`, `serializable_for_update`: 0 in 45 | `bin/exp-isolation --threads 2,8,32 --trials 5 --ops 2000 --db clearinghouse_exp3 --out results/exp3-isolation/20260925T193616Z-quiet` | `results/exp3-isolation/20260925T193616Z-quiet/results.json`, `runs[].summary.anomalies`, `.trials_with_anomalies` | 2.4 at start, 9.5 at end, no trial above 12 | MEASURED (quiet) |
| 3 | Throughput cost of SERIALIZABLE against `FOR UPDATE` | `rc_for_update` against `serializable_for_update`: 1,087.8 vs 603.7 ops/s at 2 threads, 867.9 vs 661.5 at 8, 1,390.4 vs 178.9 at 32; at 32 threads, retries 445 per 100 ops, p99 400.9 vs 73.5 ms, 2,790 of 10,000 operations ran out of retries | same run | same file, `runs[].summary.ops_per_s_mean` (with `_min`, `_max`), `p50_ms`, `p99_ms`, `retries_per_100_ops`, `exhausted` | same | MEASURED (quiet) |
| 4 | Sequences and operations, against the ledger | 300 sequences, 17,826 operations, every check passed | `CLEARINGHOUSE_DB=clearinghouse_test_model bin/model-test --sut ledger --sequences 300 --max-length 80 --seed 1` | `results/exp4-model/ledger-seed1-n300-l80.json`, `sequences`, `operations`, `passed` | 40 to 60 | MEASURED |
| 4 | Sequences and operations, against the API | seed 1: 300 and 17,826; seed 2: 300 and 18,091; every check passed | `... bin/model-test --sut api --sequences 300 --max-length 80 --seed 1`, and `--seed 2` | `results/exp4-model/api-seed1-n300-l80.json`, `api-seed2-n300-l80.json`, same fields | 40 to 60 (seed 1), 54 to 35 (seed 2) | MEASURED |
| 4 | Real bugs found by the model | 1 (`docs/bugs/model-settlement-fee-over-gross.md`), found in development and fixed before the final runs | the development runs in `docs/design/model-testing.md` | `docs/bugs/model-*.md` | n/a | MEASURED |
| 5 | Discrepancies injected and detected, by type | 60 of 60: missing 6/6, duplicate 10/10, amount mismatch 10/10, fee mismatch 10/10, late 9/9, unknown payment 15/15 | `CLEARINGHOUSE_ENV=experiment CLEARINGHOUSE_DB=clearinghouse_test_disputes bin/exp-reconciliation --reset` | `results/exp5-reconciliation/seed-1-full.json`, `score.injected`, `score.detected`, `exceptions_by_reason` | 115 before, 109 after | MEASURED |
| 5 | False exceptions | **0** | same run | same file, `score.false_exceptions` | same | MEASURED |
| 5 | Explainability at month end, before and after resolving | 96.24% to 100% by flow type before, 100% for every flow type after | same run | same file, `explainability_before_resolving`, `explainability_after_resolving` | same | MEASURED |
| 6 | Healthy endpoints' time to delivery, FIFO | p50 41.413 s, p99 139.138 s | `bin/exp-webhooks --runs fifo,isolated,isolated-kills,isolated-cap4 --out results/exp6-webhooks/20260925T193937Z-quiet` | `results/exp6-webhooks/20260925T193937Z-quiet/summary.json`, `runs[run=fifo].ttd_s.p50`, `.p99` | 9.5 at start (left over from experiment 3), 7.8 at end | MEASURED (quiet) |
| 6 | The same, per-endpoint isolation | p50 0.073 s, p99 0.128 s | same run | same file, `runs[run=isolated].ttd_s.p50`, `.p99` | same | MEASURED (quiet) |
| 6 | Duplicate delivery rate with workers killed, and missing deliveries | 4 of 5,021 (0.08%) with 15 kills; **0 missing** | same run | same file, `runs[run=isolated-kills].duplicate_rate`, `.duplicates`, `.worker_kills`, `.missing` | same | MEASURED (quiet) |
| 6 | Claim throughput, no HTTP | FIFO 2,338 and isolated 2,497 deliveries a second (about equal) | `bundle exec ruby exp/webhooks/claim_bench.rb 32 375` | `results/exp6-webhooks/20260925T193937Z-quiet/claim_bench.json`, `results[].per_second` | 7.8 | MEASURED (quiet) |
| 7 | Branch coverage and mutation score | mutation 98.00% killed (7,162 of 7,308), 99.94% with documented equivalents excluded; branch coverage 94.16% of tracked code | `bin/quality-report --reuse-mutant` over 4 mutant sessions, at commit `7091fc6` | `results/exp7-quality/summary.json`, `results/exp7-quality/README.md` | loaded machine (the report doesn't record it) | PROVISIONAL: the existing report, not a final run. A full single mutant run at `2860114` finished on 2026-09-25 (session `01a0d5d7-1825-76f4-91d6-54651721d2ea`, in `.mutant/results`, not committed). Its report (`bin/quality-report --reuse-mutant`) has not been generated yet. |
| 8 | `confirm` latency under open-loop load (the load generator sweep) | not run | `bin/loadtest sweep -scenario confirm ...` against `bin/server` and `bin/sim` | `results/exp8-confirm-latency/<UTC time>/summary.json` | n/a | NOT RUN in the final runs |
| 8 | Replay outcomes per policy (none, model_only, model_rules): disputes, dispute losses with the **assumed** 15.00 USD fee, legitimate revenue blocked, review holds, net | disputes 3,213 / 2,986 / 2,986; losses $535,657.76 / $472,390.72 / $472,390.72; legitimate blocked $0 / $40,359.44 / $40,359.44; holds 0 / 0 / 2,496 ($413,409.07 held); net $0 / +$22,907.60 / +$22,907.60 | `bin/exp-replay --replay ~/Documents/RiskGate/data/export_real/test_replay.jsonl --policy <policy> --label full --reset-db ...` (full commands in each `.md`), RiskGate `016337a`, `model_sha256` `a75d7ac4071e27f8f72bcf91c0fa6f2c8e0ecaf5ba032aad0e9e30df919ce540` | `results/exp8-replay/20260925T020100Z-full-<policy>/<policy>.json`, `money.disputes`, `money.dispute_losses_cents`, `money.legit_blocked`, `holds`, `money.net.net_cents` | 28 to 33 at start, 7 to 11 at end; the three ran concurrently | MEASURED (latency from these runs is not quotable: a system sleep mid-run) |
| 9 | Payments unchecked during a RiskGate outage and after it | kill: 3,240 of 6,000, first checked payment 2.06 s after the restart; freeze: 2,063 of 6,000, first checked 0.32 s after the thaw | measured by RiskGate's run of `bin/exp-risk-failure` against the real service (`--mode both --rate 200`, RiskGate `016337a`) | `~/Documents/RiskGate/results/exp9/riskgate-{kill,freeze}.json`, `unchecked`, `phases` (in the RiskGate repository) | 6 to 8 | MEASURED, with a caveat: in kill mode the breaker also tripped once per healthy phase (about 415 unchecked each), cause unconfirmed; kill-mode healthy-phase numbers are not cited |
| 9 | Risk step latency bound while RiskGate is down | client max 57.3 ms (kill) and 59.0 ms (freeze) against a 50 ms deadline; 16 calls paid the full deadline in freeze | same run | same files, `overall`, `phases` | 6 to 8 | MEASURED |

`bin/ci` on main at `9edf784` (the coverage merge) passed on 2026-09-25: 1,804 examples, 0
failures, `srb tc` clean, rubocop clean over 400 files, the product coverage floor met.
