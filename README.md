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

Not merged on this branch yet, and built on their own branches: the scheduler that runs every
clock-driven sweep in order, the wiring of risk-review holds into payouts, and the
mutation-testing harness.

## Results

Every number below waits for the final runs on a quiet machine. The development and smoke runs
so far were made on a machine shared with other build jobs (load averages of 15 to 70 on 12
cores), and the design notes keep them as checks of the method, not as results.

| # | Experiment | What it measures | Result |
|---|---|---|---|
| 1 | Retry storm | Double charges per implementation (no idempotency, naive check-then-insert, Clearinghouse), counted from the acquirer's own books, with the acquirer dropping responses after committing | pending final run |
| 2 | Crash at every recovery point | Recovery points crashed at, across every mutating flow, and how many recovered with a balanced ledger and the same client response | pending final run |
| 3 | Isolation level shootout | Anomalies (over-refunds, lost updates, payout double-spends) and the throughput cost of READ COMMITTED, `FOR UPDATE` and SERIALIZABLE with retry | pending final run |
| 4 | Model-based testing | Random operation sequences checked against a reference model after every step: sequences and operations run, failures found | pending final run |
| 5 | Reconciliation | A simulated month with injected settlement discrepancies of six types: detected by type, false exceptions, explainability before and after | pending final run |
| 6 | Webhooks under hostile endpoints | Healthy endpoints' time to delivery, p50 and p99, FIFO against per-endpoint isolation, and the duplicate rate with workers killed mid-run | pending final run |
| 7 | Code quality | Branch coverage and mutation score on the ledger, idempotency and money core, with surviving mutants explained | pending final run |
| 8 | Throughput and end to end | `confirm` latency (p50, p99, p99.9) under open-loop load, and the RiskGate replay through the API | pending final run |
| 9 | RiskGate fails | Payments that went through unchecked while RiskGate was down, and the confirm step's latency bound during the outage | pending final run |

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
| `bin/storm`, `bin/crash-matrix`, `bin/exp-isolation`, `bin/model-test`, `bin/exp-reconciliation`, `bin/exp-webhooks`, `bin/loadtest`, `bin/exp-risk-failure` | experiments 1 to 6, 8 and 9 |

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
| 7 | `bin/mutation`, on branch `pr/quality-mutant-config`, not merged here. The one-command report is still in progress | |
| 8 | `bin/loadtest sweep -scenario confirm -rates 10,25,50,100,200 -warmup 10s -duration 60s -slo-p99 <objective> -label "<machine>"` against `bin/server` | `docs/design/loadgen.md` |
| 9 | `bin/exp-risk-failure --rate 100 --riskgate-bin <path to RiskGate>` | `docs/design/risk-integration.md`, `results/exp9-risk-failure/README.md` |

The end-to-end half of experiment 8 (RiskGate's test month replayed through `confirm`) is
not on this branch.

## Design and reading

`DESIGN.md` is the engineering design doc: the money-flow table, every policy choice with its
reason, the confirm flow and its recovery points, the experiments, and a log of the bugs the
harness caught. The design is built from public engineering writing, credited there: Brandur
Leach's posts on idempotency keys and API versioning, Stripe's posts on idempotency and on its
Ledger system, Stripe's docs on webhook signatures and test clocks, and the Smokescreen
README.
