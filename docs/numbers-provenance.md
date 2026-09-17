# Where every number comes from

Every number the README or a resume might quote, with the command that produces it, the file
it lands in, and its status. Nothing here is a result yet. Each row stays **PENDING** until the
final run on a quiet machine, and a number moves to the README (and to Sanjith's numbers
ledger, which lives outside this repo) only with the machine, Postgres version and command
from the results file beside it.

Rules that apply to every row:

- A number is quoted from the results file, never from memory or from a smoke run. Smoke
  directories are labelled `smoke` in their name and in the JSON.
- The machine label travels with the number: CPU, cores, memory, Postgres version and whether
  it runs in Docker, pool size, and the load average the run recorded. A run whose recorded
  load average says the machine was busy is not quotable.
- Baseline numbers (the naive storm, the FIFO queue, READ COMMITTED read-then-write) are
  quoted only next to the careful version's number from the same run, and each baseline must
  be rerunnable with the command in its row.
- Unflattering numbers are published with their explanation, the throughput cost of
  SERIALIZABLE in particular.

Rows marked *not on this branch* use a tool that exists on another branch and has not been
merged here yet. Its command and path are as they are on that branch.

| # | Number | Command | Results file, field | Status |
|---|---|---|---|---|
| 1 | Double charges, no idempotency | `bin/storm --impl all --intents 1000 --concurrency 16 --drop-rate 0.1 --seed 1 --label full` | `results/exp1-retry-storm/<UTC time>-full/results.json`, `results[impl=none].double_charges` | PENDING |
| 1 | Double charges, naive check-then-insert | same run | same file, `results[impl=naive].double_charges` | PENDING |
| 1 | Double charges, Clearinghouse (must be 0) | same run | same file, `results[impl=clearinghouse].double_charges` | PENDING |
| 1 | Charged but not in the ledger, per implementation | same run | same file, `results[*].charged_not_recorded` | PENDING |
| 1 | Clients given identical and truthful answers, per implementation | same run | same file, `results[*].identical_body_rate`, `results[*].truthful_answer_rate` | PENDING |
| 1 | The same three with baselines holding the intent instead of failing it | the command above plus `--baseline-on-unknown hold` | a second `results/exp1-retry-storm/<UTC time>-full/results.json` | PENDING |
| 2 | K recovery points crashed at | `bin/crash-matrix --recovery completer`, and `bin/crash-matrix` (retry mode) | `results/exp2-crash-matrix/<UTC time>-<mode>/report.json`, `registry_crash_points` | PENDING |
| 2 | M flows those points span | same run | same file, `registry_flows` and `headline` | PENDING |
| 2 | Cases recovered, and cases failed (must be 0) | same run | same file, `passed`, `failed` | PENDING |
| 3 | Anomalies per strategy: over-refunds, lost updates, payout double-spends, balance drift | `bin/exp-isolation --threads 2,8,32 --trials 5 --ops 2000` | `results/exp3-isolation/results.json`, per strategy and thread count: `over_refunds`, `lost_updates`, `payout_double_spends`, `balance_drift_cents` | PENDING |
| 3 | Throughput cost of SERIALIZABLE against `FOR UPDATE` | same run | same file, `ops_per_s_mean` (with min and max), `p50_ms`, `p99_ms`, `retries_per_100_ops` | PENDING |
| 4 | Sequences run and operations executed, against the ledger | `bin/model-test --sut ledger --sequences 300 --max-length 80 --seed 1` | `results/exp4-model/ledger-seed1-n300-l80.json`, `sequences`, `operations`, `passed` | PENDING |
| 4 | Sequences run and operations executed, against the API | `bin/model-test --sut api --sequences 150 --max-length 60 --seed 1` | `results/exp4-model/api-seed1-n150-l60.json`, same fields | PENDING |
| 4 | Real bugs found by the model (count, each in `docs/bugs/`) | the runs above | `docs/bugs/model-*.md` | PENDING |
| 5 | Discrepancies injected and detected, by type | `CLEARINGHOUSE_ENV=experiment CLEARINGHOUSE_DB=<an experiment database> bin/exp-reconciliation --reset` | `results/exp5-reconciliation/seed-1-full.json`, `score.injected`, `score.detected`, `exceptions_by_reason` | PENDING |
| 5 | False exceptions (must be 0) | same run | same file, `score.false_exceptions` | PENDING |
| 5 | Explainability at month end, before and after resolving exceptions | same run | same file, `explainability_before_resolving`, `explainability_after_resolving` | PENDING |
| 6 | Healthy endpoints' time to delivery, p50 and p99, FIFO | `bin/exp-webhooks` | `results/exp6-webhooks/summary.json`, `runs[run=fifo].ttd_s.p50`, `.p99` | PENDING |
| 6 | The same, per-endpoint isolation | same run | same file, `runs[run=isolated].ttd_s.p50`, `.p99` | PENDING |
| 6 | Duplicate delivery rate with workers killed, and missing deliveries (must be 0) | same run | same file, `runs[run=isolated-kills].duplicate_rate`, `.missing` | PENDING |
| 7 | Branch coverage on `lib/`, and on the ledger and idempotency groups | `bin/ci` with SimpleCov; the per-group report script is *not on this branch* | `coverage/` (not committed) until the report script lands | PENDING |
| 7 | Mutation score on the ledger, idempotency and money core, and surviving mutants explained | `bin/mutation`, *not on this branch* (`pr/quality-mutant-config`) | the mutation branch's results, per subject group | PENDING |
| 8 | `confirm` latency p50, p99, p99.9 at each rate, and the highest rate inside the objective | `bin/loadtest sweep -scenario confirm -rates 10,25,50,100,200 -warmup 10s -duration 60s -slo-p99 <objective> -label "<machine>" -out results/exp8-confirm-latency/<UTC time>` against `bin/server` and `bin/sim` | `results/exp8-confirm-latency/<UTC time>/summary.json` (without `-out` it goes to `results/raw/loadgen/`, which is not committed) | PENDING |
| 8 | End-to-end replay outcomes through `confirm`: disputes, dispute losses (with the assumed 15.00 USD fee, labelled as assumed), legitimate revenue blocked, net, per policy | the replay driver, *not on this branch* | not yet defined | PENDING |
| 9 | Payments unchecked during a RiskGate outage and in the tail after it, kill and freeze | `bin/exp-risk-failure --rate 100 --riskgate-bin <RiskGate binary>` | `results/exp9-risk-failure/{riskgate,fake-riskgate}-{kill,freeze}.json`, `unchecked`, `unchecked_by_reason`, `phases` | PENDING |
| 9 | Risk step latency bound while RiskGate is frozen (deadline plus overhead) | same run | same files, `phases` (max service time before and after the breaker opens) | PENDING |

The smoke and development results already in `results/` (experiments 1, 2, 4, 5, 6 and 9)
were made on a machine with load averages of 15 to 70 on 12 cores. The design notes use them to
show the method works. None of them is quotable. The experiment 2 counts (48 points across 5
flows, all recovered, in `results/exp2-crash-matrix/`) do not depend on load, but they predate
the `review.reject` scenario, so the final run replaces them too.
