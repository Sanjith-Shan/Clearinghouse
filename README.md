# Clearinghouse: Payments API and Double-Entry Ledger

A payments API in Ruby with an append-only double-entry ledger in Postgres. Merchants create
and confirm payments, capture them in full or in part, refund them and pay out their balance.
Every movement of money is a balanced ledger transaction that the database itself checks. The
project exists to show that money is never created, lost or moved twice under retries,
crashes and concurrency, and to measure that rather than assert it.

**This is a simulation.** The card acquirer, the card networks and the banks are simulated
processes in this repo. Payment methods are test tokens such as `pm_card_visa`. There are no
card numbers, no PAN storage and no PCI scope, and no real money moves.

## Quickstart

With Ruby 3.3, `libpq` and Docker installed (full setup in `CONTRIBUTING.md`):

```
bundle install
docker compose up -d db && bin/demo
```

`bin/demo` creates and empties its own database (`clearinghouse_demo`), starts the acquirer
simulator, a fake RiskGate and the API server on free ports, and walks one merchant through two
simulated weeks using the Ruby client in `clients/ruby`:

1. create and confirm a payment with an `Idempotency-Key`, then send the same call again and
   get `Idempotent-Replayed: true` with a byte-identical body (and a 400 when the key is
   reused with different parameters)
2. a declined card, as a typed `card_error` with its `decline_code`
3. a partial refund
4. a manual-capture payment captured for less than was authorized
5. a payment on the card the simulator disputes as fraud
6. `bin/explain` on the payment and the refund, both OPEN, then the settlement file
   reconciled three simulated days later, after which both are EXPLAINED
7. the availability sweep, the balance, and a payout
8. the acquirer's notifications eight days later: the bank pays the payout and the dispute
   opens, taking the amount and a 15.00 USD dispute fee (an assumed figure) from available
9. the dispute won, its two settlement lines reconciled, and the dispute flow EXPLAINED

The API runs on the wall clock. Everything that happens days later is driven with test clocks
moved ahead, the way the specs do it. A run takes under a minute and stops its child processes
on exit.

## The system

```
          clients/ruby · sim/loadgen (Go) · bin/storm · RiskGate's replay driver
                                   |
                     HTTP JSON API (Sinatra on Puma), lib/clearinghouse/api
                                   |
        +--------------------------+---------------------------+
        |                          |                           |
  auth: a secret key        versioning: dated versions,   idempotency: keys, atomic phases,
  per merchant              change modules, golden files  recovery points, SERIALIZABLE + retry
        |
  payments (PaymentIntents, refunds) · balances (availability, review holds) · payouts
        |                  \                                   \
        |                   risk step --> RiskGate (Go)          acquirer client --> bin/sim
        |                   50 ms deadline, circuit breaker,     (separate process: authorize,
        |                   fail open                             capture, void, refund, payouts,
        |                                                         notifications, settlement files)
  ledger: append-only, double entry, checked at COMMIT by a deferred trigger (Postgres 16)
        |
  events table: the outbox, written in the same transaction as the state change
        |
  bin/dispatcher --> webhook_deliveries --> bin/webhook-worker
                     (SKIP LOCKED leases, per-endpoint in-flight cap and breaker,
                      SSRF-safe egress, signed with rotation)
        |
  merchant endpoints, and RiskGate, which dedupes on event id

  bin/poller:       applies the acquirer's notification feed (disputes, payout results)
  reconciler:       clears each settlement-file line against the ledger, or raises a typed exception
  bin/data-quality: open flows past their SLA, orphan clearing balances, explainability
  bin/completer:    finishes abandoned requests, expires authorizations, reaps old keys
  bin/explain:      the ledger trail of one payment, refund, dispute or payout
```

Every component reads time from a `Clearinghouse::Clock`. Tests and the demo use a test clock
that moves only when told to, so settlement delays, retries over days and key expiry are
testable without waiting.

## Results

Measured on 2026-09-24 and 25 at commit `2860114`: Apple M3 Pro, 12 cores, 18 GB, PostgreSQL
16.15 in Docker, Ruby 3.3.12. The timing numbers (experiments 3 and 6) come from runs on a
quiet machine. The counts (double charges, crash points, discrepancies, dollars) don't depend
on load, and several of those runs shared the machine with other experiments. Each row's load
average, command and results file are in `docs/numbers-provenance.md`.

| # | Experiment | What it measures | Result |
|---|---|---|---|
| 1 | Retry storm | Double charges per implementation, counted from the acquirer's own books, with 1,000 intents × 16 concurrent clients and 10% of acquirer answers dropped after commit | No idempotency: **95** cards charged more than once. Naive check-then-insert: **35**. Clearinghouse: **0**, with every charge in the ledger and all 16,000 clients given the same true answer. Both baselines left about 100 charges out of the ledger. |
| 2 | Crash at every recovery point | Recovery points crashed at, across every registered flow, and how many recovered with a balanced ledger and the same client response | Crashed at **88 points across 13 flows, recovered at all 88**, in both recovery modes (client retry, and the completer). 0 failures. |
| 3 | Isolation level shootout | Anomalies and throughput of READ COMMITTED read-then-write, `FOR UPDATE`, SERIALIZABLE with retry, and SERIALIZABLE with `FOR UPDATE` (what ships), at 2, 8 and 32 threads | Read-then-write had anomalies in **15 of 15** trials (up to 370 over-refunds and 15,656 lost updates). The safe strategies had **0 in 45**. The cost: `FOR UPDATE` alone was **1.8x, 1.3x and 7.8x** faster than the shipped SERIALIZABLE, and at 32 threads 28% of the SERIALIZABLE operations ran out of retries. It ships anyway, for reasons given in `docs/design/isolation.md`. |
| 4 | Model-based testing | Random operation sequences checked against a reference model after every step | **900 sequences, 53,743 operations** (ledger, and the API with two seeds), every check passing. One real bug found in development, since fixed. |
| 5 | Reconciliation | A simulated month (1,500 payments) with 60 injected settlement discrepancies of six types | **60 of 60** detected as the right type, **0** false exceptions. Explainability 96.2 to 100% by flow type before resolving, 100% after. |
| 6 | Webhooks under hostile endpoints | Healthy endpoints' time to delivery, FIFO against per-endpoint isolation, with 17 of 100 endpoints failing or hanging, and with workers `kill -9`ed | FIFO p50 / p99 **41.4 s / 139.1 s**. Isolation **0.073 s / 0.128 s**. With 15 workers killed, 0 deliveries missing and 4 of 5,021 duplicated (**0.08%**). |
| 7 | Code quality | Branch coverage, and mutation score on the money core, ledger, webhook signatures and SSRF policy, with surviving mutants explained | **Provisional**, from the existing report, not the final run: mutation score **98.00%** (7,162 of 7,308 killed; 99.94% with the 142 survivors documented as equivalent left out), branch coverage 94.16% of tracked code, at commit `7091fc6` on a loaded machine, merged from 4 mutant sessions. A single full mutant run at `2860114` completed, and its report is still to be generated. |
| 8 | End to end | RiskGate's IEEE-CIS test month (92,427 payments) replayed through `confirm` under no checks, the model alone, and model plus rules | No checks: 3,213 disputes, **$535,657.76** lost including an **assumed** $15 fee each. Model block: 227 fraud and 157 legitimate payments blocked, **net +$22,907.60**. The rules added 2,496 review holds ($413,409.07) and changed no money. The `confirm` latency sweep was not run for these results. |
| 9 | RiskGate fails | Payments that went through unchecked while RiskGate was down, and the risk step's latency bound. Measured by RiskGate's run of `bin/exp-risk-failure` against the real service | At 200 calls/s with a 10 s outage: kill **3,240** of 6,000 unchecked (first checked payment 2.06 s after restart), freeze **2,063** of 6,000 (0.32 s after thaw). Max client latency **57 to 59 ms** against a 50 ms deadline. Caveat: in kill mode the breaker also tripped once per healthy phase, cause unconfirmed. Those numbers are not cited. |

Where each number comes from, with its command and results path, is in
`docs/numbers-provenance.md`.

## What's inside

```
lib/clearinghouse/
  money.rb, currency.rb, fees.rb   integer minor units, ISO 4217 exponents, fees rounded half-even
  clock.rb                          real and test clocks
  ledger/                           posting, flows (the money-flow table as code), checker,
                                    invariants, clearing report, explain
  idempotency/                      keys, fingerprints, atomic phases, runner, SERIALIZABLE retry,
                                    turnstile, completer, reaper, crash hook
  payments/                         PaymentIntents as a transition table, confirm, capture,
                                    cancel, refunds, authorization expiry
  balances/, payouts/               availability, risk-review holds, payouts as phases around
                                    the bank call, bank notifications
  risk/                             RiskGate client: one deadline, keep-alive pool, circuit breaker
  api/                              Sinatra app, errors, auth, params, routes
  versioning/                       date-named versions and the three change modules
  webhooks/                         endpoints, dispatcher, queue, workers, retries, breakers,
                                    signatures, SSRF-safe egress
  acquirer/                         the acquirer client, which keeps Unknown apart from Unavailable,
                                    and the notification poller
  disputes/                         disputes opened and closed from the acquirer's feed
  reconciliation/                   settlement files matched line by line, exceptions, data quality
  testing/model/                    the reference model, generator and shrinker (experiment 4)
  experiments/                      the retry storm's baselines and the reconciliation month
sim/
  lib/acquirer_sim/                 the acquirer simulator: seeded, misbehaves on command,
                                    writes settlement files with injected discrepancies
  fake_riskgate/                    a stand-in for RiskGate's /v1/assess that fails on command
  loadgen/                          open-loop load generator in Go, HdrHistogram
  experiments/                      the storm, crash-matrix, isolation and risk-failure harnesses
exp/webhooks/                       experiment 6's hostile endpoint server and analysis
clients/ruby/                       the client library: one key per logical call, typed errors
clients/go/webhooksig/              webhook signature verifier in Go (RiskGate's passes the same vectors)
db/migrations/                      schema, triggers and role grants
docs/design/                        one design note per area
docs/bugs/                          bugs the tests and experiments caught
```

Tools in `bin/`:

| command | what it does |
|---|---|
| `bin/demo` | the scripted tour above |
| `bin/server`, `bin/sim`, `bin/fake-riskgate` | the API (port 4000), the acquirer simulator (4600), a fake RiskGate (4700) |
| `bin/completer` | expiry sweep, completer and reaper on a loop, or `--once` |
| `bin/poller`, `bin/data-quality` | the acquirer's notification feed; the clearing and SLA report |
| `bin/dispatcher`, `bin/webhook-worker` | webhook fan-out and delivery |
| `bin/explain <id>` | the ledger trail of one flow, EXPLAINED or OPEN |
| `bin/migrate`, `bin/ci` | migrations, and everything CI runs |
| `bin/changelog`, `bin/gen-signature-vectors` | regenerate `docs/api-changelog.md` and `spec/fixtures/signatures.json` |
| `bin/storm`, `bin/crash-matrix`, `bin/exp-isolation`, `bin/model-test`, `bin/exp-reconciliation`, `bin/exp-webhooks`, `bin/quality-report`, `bin/loadtest` and `bin/exp-replay`, `bin/exp-risk-failure` | experiments 1 to 9 |

## Running the tests

```
export CLEARINGHOUSE_DB=clearinghouse_test
bin/migrate
bin/ci                       # srb tc, rubocop, migrate, rspec, go vet and go test
bundle exec rspec spec/ledger
```

The specs run against real Postgres, and the payments specs against a real simulator on an
ephemeral port. SimpleCov collects branch coverage on every run.

## Running the experiments

Each writes its results, with the machine, Postgres version and the command, under
`results/`. Raw logs go to `results/raw/`, which is not committed.

| # | command | design note |
|---|---|---|
| 1 | `bin/storm --impl all --intents 1000 --concurrency 16 --drop-rate 0.1 --seed 1 --label full`, then the same with `--baseline-on-unknown hold` | `docs/design/storm.md` |
| 2 | `bin/crash-matrix` and `bin/crash-matrix --recovery completer` | `docs/design/crash-matrix.md` |
| 3 | `bin/exp-isolation --threads 2,8,32 --trials 5 --ops 2000` | `docs/design/isolation.md` |
| 4 | `bin/model-test --sut ledger --sequences 300 --max-length 80 --seed 1`, and `--sut api` | `docs/design/model-testing.md` |
| 5 | `CLEARINGHOUSE_ENV=experiment CLEARINGHOUSE_DB=<an experiment database> bin/exp-reconciliation --reset` | `docs/design/reconciliation.md`, `results/exp5-reconciliation/README.md` |
| 6 | `bin/exp-webhooks` | `results/exp6-webhooks/README.md`, `docs/design/webhooks.md` |
| 7 | `bin/quality-report` (the full mutant run, coverage and Sorbet), or `bin/quality-report --reuse-mutant` to report on the last mutant session | `docs/design/quality.md`, `results/exp7-quality/README.md` |
| 8, replay | `bin/exp-replay --replay <RiskGate's test_replay.jsonl> --policy none\|model_only\|model_rules --label full --reset-db ...`, the full procedure in the design note | `docs/design/replay.md`, `results/exp8-replay/README.md` |
| 8, latency | `bin/loadtest sweep -scenario confirm -rates 10,25,50,100,200 -warmup 10s -duration 60s -slo-p99 <objective> -label "<machine>"` against `bin/server` | `docs/design/loadgen.md` |
| 9 | `bin/exp-risk-failure --rate 100 --riskgate-bin <path to RiskGate>` | `docs/design/risk-integration.md`, `results/exp9-risk-failure/README.md` |

Experiment 8 has two parts: the `bin/loadtest` latency sweep, and the replay of RiskGate's
test month through `confirm` with `bin/exp-replay`. Only the replay was run for the results
above.

## Design and reading

`DESIGN.md` is the engineering design doc: the money-flow table, every policy choice with its
reason, the confirm flow and its recovery points, the experiments, and a log of the bugs the
harness caught. The design is built from public engineering writing, credited there: Brandur
Leach's posts on idempotency keys and API versioning, Stripe's posts on idempotency and on its
Ledger system, Stripe's docs on webhook signatures and test clocks, and the Smokescreen
README.
