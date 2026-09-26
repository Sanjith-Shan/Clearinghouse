# Experiment 8: the replay through Clearinghouse and RiskGate

The method, what is real and what is simulated, the assumed 15.00 USD dispute fee, and the
commands for the full runs: `docs/design/replay.md`.

Each directory is one `bin/exp-replay` run, with `<policy>.json` (everything) and
`<policy>.md` (the tables plus the command, machine, load and RiskGate ruleset). Only
aggregates are stored, never rows.

## Full runs (the published result)

RiskGate's IEEE-CIS test month, all 92,427 payments (simulated 2018-05-01 to 2018-06-09), in
`(TransactionDT, TransactionID)` order through `confirm`, once per policy:

- `20260925T020100Z-full-none/none.{md,json}`: no risk check.
- `20260925T020100Z-full-model_only/model_only.{md,json}`: RiskGate with `rules/model_only.rules`
  (block at `risk_score >= 50`), on 127.0.0.1:8092, database `clearinghouse_test_exp3`.
- `20260925T020100Z-full-model_rules/model_rules.{md,json}`: RiskGate with `rules/default.rules`
  (the same block rule plus review rules), on 127.0.0.1:8093, database `clearinghouse_test_api`.
  `none` used `clearinghouse_test_loadgen`.

Setup common to all three:

- Clearinghouse commit `2860114`. RiskGate binary built from RiskGate commit `016337a` (clean),
  `-model models/ieee -lists rules/lists.json -snapshot-interval 0 -decision-log off`. Each
  RiskGate started from its own fresh copy of the warm snapshot `var/exp8_warm` (all 498,113
  pre-test payments, built at RiskGate `3e72fda`). `GET /v1/info` returned `model_sha256`
  `a75d7ac4071e27f8f72bcf91c0fa6f2c8e0ecaf5ba032aad0e9e30df919ce540` before each model run.
  The driver PUT the policy's rules, which RiskGate recorded as ruleset version 2 in both runs.
  Each RiskGate was stopped by PID after its run.
- Apple M3 Pro, 12 cores, 18 GB, PostgreSQL 16.15 in Docker, Ruby 3.3.12. Confirm's
  RiskGate deadline was 50 ms.
- **The three ran concurrently**, from 02:01Z to 08:14Z on 2026-09-25, each one sequential
  client, at 4.3 to 4.5 rows a second. 1-minute load before and after: none 28.3 and 11.2,
  model_only 32.9 and 6.8, model_rules 30.0 and 6.6. Other experiments (mutation testing,
  the isolation and webhook reruns) shared the machine during parts of the window.
- **A missing index, fixed mid-run.** The runs slowed to about 1.5 rows a second because the
  idempotency reaper's `DELETE` fired a foreign-key check that sequentially scanned
  `payment_intents`, which had no index on `locked_by` (49.7 s per reap). At 06:06:56Z an
  index on `payment_intents(locked_by) WHERE locked_by IS NOT NULL` was added to the three
  replay databases, and speed recovered. It changed speed only: no payment, dispute or dollar
  outcome depends on it. The fix ships as a migration, with its entry in `docs/bugs/`.
  It is noted in each run's log (`_coord/final/logs/exp8-*.log`, outside the repo).

| | none | model_only | model_rules |
|---|---:|---:|---:|
| Payments | 92,427 | 92,427 | 92,427 |
| Approved | 92,427 ($12,726,599.00) | 92,043 ($12,626,377.52) | 92,043 ($12,626,377.52) |
| Blocked | 0 | 384 ($100,221.48) | 384 ($100,221.48) |
| Fraud caught (fraud-labelled and blocked) | 0 | 227 ($59,862.04) | 227 ($59,862.04) |
| Legitimate revenue blocked | 0 | 157 ($40,359.44) | 157 ($40,359.44) |
| Fraud through, and disputed | 3,213 ($487,462.76) | 2,986 ($427,600.72) | 2,986 ($427,600.72) |
| Dispute losses, with an **assumed** $15.00 fee each | $535,657.76 | $472,390.72 | $472,390.72 |
| Reviews (payout held) | 0 | 0 | 2,496 ($426,527.49 captured, $413,409.07 of merchant net held) |
| Net of the checks, against none | $0.00 | **+$22,907.60** | **+$22,907.60** |
| Went through unchecked (RiskGate missed the 50 ms deadline) | - | 24 ($2,384.01) | 8 ($2,274.13) |
| Ledger invariant violations | 0 | 0 | 0 |

Fields: `money.approved`, `.blocked`, `.fraud_caught`, `.legit_blocked`, `.disputes`,
`.dispute_losses_cents`, `.reviews`, `.risk_unavailable`, `.net.net_cents`, `holds`,
`ledger_invariant_violations`, `load_average`.

How to read it:

- **Net** is what the checks saved (blocked fraud plus the assumed fee each would have cost,
  $63,267.04) minus the legitimate revenue they blocked ($40,359.44). It is not revenue.
  The dispute fee is assumed at Stripe's published US 15.00 USD, not measured.
- **model_only and model_rules have the same money outcome, and that is expected.** Both
  rule files contain the same single block rule, and `default.rules` adds only review rules.
  In Clearinghouse a review lets the payment through and holds the merchant's payout. So the
  rules' whole effect here is the 2,496 review holds ($413,409.07 held). Reviews are never
  resolved in the replay, so what those holds would have saved is not measured.
- In every run, disputes counted through `GET /v1/disputes` equal the simulator's own count,
  and no legitimate row was disputed.
- The payments that went through unchecked were all deadline timeouts (checked in the
  databases), none of them the `-max-future-skew` refusal that would mean a broken run. They
  are the fail-open cost at this load.
- **Latency is not quotable.** Confirm p50 was 36 to 40 ms and p99 231 to 250 ms, and the
  risk step was p50 0.68 to 0.75 ms and p99 4.3 to 5.2 ms (0.5 to 0.7% of confirm), all
  from a loaded run with the three replays going at once. Each run's maximum confirm was
  about 4,492 s. That is a system sleep: `pmset -g log` shows the Mac sleeping on battery
  between about 22:00 and 23:00 PT on 2026-09-24, in the middle of all three runs. So the
  latency tail includes a sleep and is not quotable. The latency number for experiment 8
  comes from the load generator's part.

## Smoke run

- `20260924T200001Z-smoke/`: the first 50 rows of RiskGate's **synthetic** export, under `none` and
  under `model_rules` against the fake RiskGate with made-up rules
  (`sim/experiments/replay/fake_policy.json`). It checks that the pieces connect. Its
  money and latency say nothing about RiskGate.
