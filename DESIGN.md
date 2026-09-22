# Clearinghouse design

Written for a reader who has never seen the repo. This file is the overview: what the system
is, how money moves through it, the policy decisions and why each was made, the one request
flow worth drawing in full, the experiments, and the bugs the tests caught. Each area has its
own note under `docs/design/` with the detail, and the links below go to them.

## Overview

Clearinghouse is a payments API with a double-entry ledger, in Ruby (Sinatra on Puma, Sequel,
Sorbet) over Postgres 16. A merchant creates a PaymentIntent, confirms it with a test payment
method, captures it (at once or later, in full or in part), refunds it, and is paid out once the
funds become available. Around that sit the parts that make it safe to run: idempotency keys
with crash recovery, a risk check against RiskGate (a separate Go service), webhooks through a
transactional outbox, and dated API versions.

It is a simulation. The acquirer, the card networks and the bank are a simulator in `sim/`,
run as a separate process so the network boundary is real. Payment methods are test tokens.
There are no card numbers and no real money.

The one property everything else serves: **money is never created, lost or moved twice.**
Three mechanisms carry it:

- **The ledger.** Every movement is a balanced transaction of debits and credits, and history
  is append-only. Postgres enforces both with triggers and role grants, so a bug in Ruby, or a
  raw SQL session, cannot write an unbalanced or edited history.
- **Idempotency with recovery points.** Every mutating request is a chain of atomic phases.
  Each phase commits in one SERIALIZABLE transaction together with the recovery point it
  reached, and every call to the acquirer sits between two phases under an idempotency key
  derived from the payment. A retry, or the completer after a crash, resumes from the last
  commit and asks the acquirer what happened instead of guessing.
- **Clearing accounts.** Every flow passes through a clearing account that must come back to
  zero when the flow completes. A flow whose clearing accounts are all at zero is
  *explained*. One that is not has money somewhere it should not be, and the clearing report
  and `bin/explain` find it without being told what the bug is.

```
  client --HTTP--> API (auth, versioning, idempotency runner)
                     |
                     +--> payments / balances / payouts --> ledger (Postgres, triggers)
                     |          |                                 |
                     |          +--> RiskGate (deadline, breaker)  +--> events (outbox, same txn)
                     |          +--> acquirer simulator (keyed calls, status query)
                     |                                                  |
  bin/completer: resumes stopped requests                bin/dispatcher --> bin/webhook-worker
                                                                          --> merchant endpoints
  acquirer feed --> bin/poller: disputes opened and closed, payouts paid or failed
  settlement files --> reconciler: each line clears its flow, or becomes a typed exception
```

## Reading list

The design is built from public engineering writing, credited here.

1. Brandur Leach, *Implementing Stripe-like Idempotency Keys in Postgres* (2017), https://brandur.org/idempotency-keys
2. Stripe, *Designing robust and predictable APIs with idempotency* (2017), https://stripe.com/blog/idempotency
3. Ilya Ganelin, *Ledger: Stripe's system for tracking and validating money movement* (2024), https://stripe.dev/blog/ledger-stripe-system-for-tracking-and-validating-money-movement
4. Brandur Leach, *APIs as infrastructure: future-proofing Stripe with versioning* (2017), https://stripe.com/blog/api-versioning
5. Stripe docs on webhook signatures, https://docs.stripe.com/webhooks
6. `stripe/smokescreen`, https://github.com/stripe/smokescreen
7. Stripe docs on test clocks, https://docs.stripe.com/billing/testing/test-clocks

What each one gave the design: atomic phases, recovery points, the completer and the reaper
(1, read and not copied; `docs/design/idempotency.md` lists what Clearinghouse does beyond
it); the idempotency contract and the retry rules on both sides of the wire (2); the immutable
log, clearing accounts that must net to zero, and explainability (3); dated versions and
version change modules (4); the `t=...,v1=...` signature header, the tolerance, and
at-least-once delivery (5); resolving and checking the address before connecting, for
webhook egress (6); the simulated clock (7).

## Money and time

- Amounts are integer minor units with an ISO 4217 exponent table (`lib/clearinghouse/currency.rb`).
  JPY and KRW have no minor unit, KWD and BHD have three. Parsing a fraction the currency
  cannot hold is an error, never a silent round.
- Fees are percentage plus fixed, computed in integers and rounded half-even. Net is defined
  as gross minus fee, so gross equals net plus fee by construction, and a property test
  checks it anyway along with the rounding bound.
- Every component reads a `Clearinghouse::Clock`. Tests use a test clock that only moves
  when told to and never moves backwards.

## The money flows

Every row is a method on `Ledger::Flows` that returns the entries, so the table and the code
cannot drift apart without a spec noticing. The example is a $100.00 card payment with our fee
of 2.9% + 30 cents ($3.20) and the acquirer's fee of 1.5% + 10 cents ($1.60). The full table,
with the review-hold rows, is in [`docs/design/ledger.md`](docs/design/ledger.md).

| Flow | Event | Debit | Credit | Clearing account after |
|---|---|---|---|---|
| payment `pi_` | Capture | processor_receivable 100.00 | merchant pending 96.80, fee_revenue 3.20 | processor_receivable 100.00 |
| payment | Settlement received | cash 98.40, processing_expense 1.60 | processor_receivable 100.00 | processor_receivable 0 |
| payment | Funds become available | merchant pending 96.80 | merchant available 96.80 | (none touched) |
| refund `re_` | Refund $40.00 | merchant available 40.00 | refund_clearing 40.00 | refund_clearing 40.00 |
| refund | Refund settled | refund_clearing 40.00 | cash 40.00 | refund_clearing 0 |
| dispute `dp_` | Dispute opened, fee $15.00 | merchant available 100.00, merchant available 15.00 | dispute_clearing 100.00, dispute_fee_revenue 15.00 | dispute_clearing 100.00 |
| dispute | Acquirer debits us | dispute_clearing 100.00 | cash 100.00 | dispute_clearing 0 |
| dispute | Dispute won | dispute_clearing 100.00 | merchant available 100.00 | dispute_clearing -100.00 |
| dispute | Acquirer returns funds | cash 100.00 | dispute_clearing 100.00 | dispute_clearing 0 |
| payout `po_` | Payout $50.00 | merchant available 50.00 | payout_clearing 50.00 | payout_clearing 50.00 |
| payout | Payout paid | payout_clearing 50.00 | cash 50.00 | payout_clearing 0 |
| payout | Payout failed | payout_clearing 50.00 | merchant available 50.00 | payout_clearing 0 |

Settlement books the acquirer's fee as our expense and clears the receivable for the full
gross. Booking cash at the gross would leave $1.60 of cash that does not exist, and clearing the
receivable at the net would leave $1.60 in clearing forever. The dispute fee is an assumed
$15.00, Stripe's published US fee. The settlement, refund-settled and acquirer dispute rows are
posted by the reconciler from the acquirer's daily settlement file
([reconciliation.md](docs/design/reconciliation.md)). The dispute rows come from the acquirer's
notification feed ([disputes.md](docs/design/disputes.md)).

## Policy choices

Each of these is a decision with a real alternative. The reason is given here, and the
design note linked from each has the detail and the specs.

**Our fee is not returned on a refund.** A refund debits the merchant for the refunded amount
only. The work the fee paid for (authorization, capture, the acquirer's fee on the capture)
already happened, and a refund does not undo it. Returning it would also make capture then
refund a way to use the platform for free. Stripe makes the same call. Reversing it later would
be one more pair of entries on the refund, pro rata for partial refunds.
([ledger.md](docs/design/ledger.md))

**The dispute fee is kept when the dispute is won.** It pays for handling the dispute, and
that cost is the same whatever the outcome. ([ledger.md](docs/design/ledger.md))

**A dispute or refund may take the available balance negative, and payouts stop at zero.**
The card network has already decided a dispute, and a refund is owed to the cardholder, so
refusing either because the merchant's balance is low only moves the loss to the platform.
The negative balance is a debt, and later captures pay it down on their own because
availability credits the same account. Payouts are refused while available is zero or
negative, checked under a row lock so a concurrent dispute cannot slip in between the check
and the payout. There is no rolling reserve and no write-off of unpaid debt. Both are policy
for a real platform and nothing here depends on them.
([ledger.md](docs/design/ledger.md), [payouts.md](docs/design/payouts.md))

**Refunds come out of available, not pending.** Debiting pending first would need each refund
to know which capture's pending funds it may touch, which is state the ledger does not hold. The
cost is that a refund of a payment still pending can take available negative for a day or two,
and the rule above covers that. The demo shows exactly this: available is -40.00 until the
captures are released.

**RiskGate fails open.** When RiskGate does not answer within the 50 ms deadline, or the
breaker is open, the payment goes ahead and the intent records `risk.decision =
risk_unavailable` with the reason. Failing closed would turn every RiskGate outage into a
payments outage for every merchant. The cost is real and has a number: every payment during
an outage goes through unchecked, plus a tail of up to one breaker cool-down after RiskGate
comes back. Experiment 9 measures it. A per-merchant fail-closed switch would be the answer
for goods where fraud losses outweigh lost sales. It is not built.
([risk-integration.md](docs/design/risk-integration.md))

**A `review` decision holds the payout, not the payment.** Blocking an uncertain payment
turns away a customer who is probably legitimate. Letting it through and holding the
merchant's payout of those funds means that if it turns out to be fraud, the dispute arrives
while the money is still on the platform. The hold is money in a separate `merchant held`
account, and payouts only ever read `available`, so there is no code path from a hold to a
bank. ([payouts.md](docs/design/payouts.md))

**`json`, not `jsonb`, for stored objects.** jsonb reorders object keys, so a merchant's
metadata and a declined intent's `last_payment_error` came back in a different order from the
one they went in with. Nothing queries inside these columns, so `json`, which keeps the text,
costs nothing. A spec caught it (`docs/bugs/payments-jsonb-key-order.md`).
([payments.md](docs/design/payments.md))

**No cancel from `processing`.** The spec's state diagram has one, and Stripe does not.
`processing` means an authorization is in flight whose outcome may not be known (the acquirer
may have timed out). A cancel there would race the confirm that owns the authorization, and a
void could reach the acquirer before the authorization it voids. The confirm finishes, or the
completer finishes it, and the intent can be canceled from wherever it lands.
([payments.md](docs/design/payments.md))

**One capture per authorization.** A partial capture captures that much and releases the rest,
as card networks allow, and the intent goes to `succeeded` either way.

**What gets stored against an idempotency key, and what is retried.** A response is stored
once the request has started and its outcome depends only on the request: every 2xx and every
4xx the same request would get again (a decline, an illegal transition, a refund past what was
captured). Parameter errors, transient conflicts (`409 lock_timeout`, 429) and every 5xx are
not stored. The key is released and a retry runs or resumes the request. The server says
which is which in `Clearinghouse-Should-Retry`, and the Ruby client follows it before its own
status rules (retry connection failures, 409, 429 and 5xx; never another 4xx), with at most two
retries, full-jitter backoff capped at 8 s, and the same key on every attempt.
([idempotency.md](docs/design/idempotency.md), [client.md](docs/design/client.md))

**Serialization retries are bounded, and running out is a 409.** A phase that hits a
serialization failure or deadlock is retried up to 8 attempts with full-jitter backoff (at most
250 ms), starting each time from the committed state. When the conflict outlasts all 8, the
client gets a retryable `409 lock_timeout` and nothing of the losing phase has committed. It
used to be a 500 (`docs/bugs/payments-concurrent-refunds-exhausted.md`).

**An unknown acquirer answer changes nothing.** A call that was sent and got no answer may have
charged the card. The intent stays `processing`, the client gets a retryable 503, and the retry
asks the acquirer under the same key before doing anything. A new attempt number, and so a
new acquirer key, is only ever started by a new confirm after a definite decline.

**Isolation: SERIALIZABLE phases with row locks inside, pending experiment 3.** Every atomic
phase runs SERIALIZABLE, and the payments code inside it locks the rows it checks with
`FOR UPDATE`. Refunds of one payment also queue on an advisory lock before their transaction
begins, because under SERIALIZABLE a waiter on a row lock still aborts once the winner commits.
`FOR UPDATE` alone protects exactly the rows the code remembers to lock. SERIALIZABLE also
protects checks that are not one row, such as a sum or an "is there another pending refund"
query, at the price of retries under contention. Experiment 3 measures that price, and if
`FOR UPDATE` alone is anomaly-free and clearly faster on this workload, this section will say
so and say which ships. ([isolation.md](docs/design/isolation.md))

**Webhooks are delivered at least once, and consumers dedupe.** Exactly-once delivery over HTTP
would need the endpoint's side effect and our record of it to commit together, and they share
no transaction. Recording before sending would turn the crash window into a lost event instead
of a duplicate, which is worse. Retries use full jitter over three days, then the delivery is
marked failed. ([webhooks.md](docs/design/webhooks.md))

## Confirm, point by point

`POST /v1/payment_intents/:id/confirm` is the flow with the most foreign calls, so it is the one
drawn in full. Each `[point]` is a recovery point, committed in the same SERIALIZABLE transaction
as the work beside it. The code is `Payments::Flows::ConfirmIntent`
(`lib/clearinghouse/payments/flows.rb`), driven by `Idempotency::Runner`.

```
 client ──POST /confirm, Idempotency-Key: k──▶ Clearinghouse                       acquirer / RiskGate
                                                   │
 [started]            key row inserted, leased     │  tx: INSERT idempotency_keys
                                                   │
 [intent_locked]      requires_* → processing,     │  tx: lock intent row, table says confirm is legal,
                      attempt + 1, intent owned    │      attempt += 1, payment_intents.locked_by = key
                                                   │
                                                   ├───── Risk::Step.call(attempt) ────────────────▶ RiskGate
 [risk_assessed]      verdict stored               │  tx: risk column; on block: requires_payment_method,
                                                   │      payment_failed event, finish with 402
                                                   │
 [authorization_      "the acquirer may now have   │  tx: recovery point only
  requested]           been asked"                 │
                                                   ├───── authorize, key pi_…:authorize:<attempt> ─▶ acquirer
                                                   │      (on resume: GET /operations/<key> first)
 [authorization_      the answer stored            │  tx: acquirer_reference, latest_charge; on decline:
  recorded]                                        │      requires_payment_method, payment_failed, finish 402
                                                   │
 [ledger_posted]      processing → succeeded       │  tx: status, capture posted to the ledger, availability
                      (or requires_capture)        │      scheduled, review hold, succeeded event (or
                                                   │      amount_capturable_updated)
                                                   │
 [finished]           response stored              │  tx: render at the request's version, store bytes,
                                                   │      release intent and key
 client ◀──────────── 200 + body ──────────────────┘
```

What a crash right after each commit leaves, and what the client's retry or the completer does:

| Crash after | Durable | Resume does |
|---|---|---|
| `started` | a leased key, nothing else | runs the whole request from the start |
| `intent_locked` | intent `processing`, attempt N, owned by the key | asks RiskGate again under `<pi>:N`. RiskGate replays its stored answer, so velocity is not counted twice, and nothing has acted on a risk answer yet |
| `risk_assessed` | the verdict | goes straight to the acquirer. RiskGate is never asked again for this attempt |
| `authorization_requested` | the promise that the acquirer may have been asked | **asks the acquirer** under `<pi>:authorize:N` and authorizes only if the answer is "nothing under that key" |
| `authorization_recorded` | the acquirer's answer | applies it: status, ledger, event |
| `ledger_posted` | the money | renders and stores the response |
| `finished` | the response | replays it, byte for byte, with `Idempotent-Replayed: true` |

A crash inside a transaction rolls that phase back and leaves the previous row. Every phase
commit is conditional on the key's lease token, so a request that stalled past its lease and
was taken over cannot commit over its successor. Capture, cancel, refund and a rejected review
follow the same rules with fewer points. The fault-injection hook
(`CLEARINGHOUSE_CRASH_AT=<flow>:<point>[:before_commit]`, armed only when `CLEARINGHOUSE_ENV`
is `test` or `experiment`) can stop the process at any of them.
[`docs/design/idempotency.md`](docs/design/idempotency.md) has the rest: the fingerprint, the
lease, what an attempt is, and the completer and reaper.

## Experiments

Each experiment runs the careful version against a baseline where there is one, so the result is
a measurement rather than a claim. **Results are pending** for all of them: the runs so far were
made on a machine shared with other build jobs, and the numbers wait for a quiet one. The
README's table is where they will go, and `docs/numbers-provenance.md` says which command and
file each number comes from.

**1. The retry storm.** N payments, each confirmed by K clients at once with the same
Idempotency-Key, while the acquirer commits and then drops a share of its responses. It runs
against no idempotency, a naive check-then-insert, and Clearinghouse, and counts charges from
the acquirer's own books, not the ledger. The smoke runs show the mechanism: the baselines
double charge or charge without recording it, and Clearinghouse charged each card once.
Results pending. ([storm.md](docs/design/storm.md))

**2. Crash at every recovery point.** For every recovery point of every registered flow, the
server is stopped there with `exit!`, restarted, and the request recovered by the client's retry
or by the completer. The checks: the flow reaches a terminal state, the ledger balances, the
acquirer's charges equal the ledger's, one event per state change, and the retry gets the
response an uninterrupted request would have. The points come from the flow registry, so a new
point cannot be skipped. Results pending. ([crash-matrix.md](docs/design/crash-matrix.md))

**3. Isolation level shootout.** Many partial refunds of one payment, plus payouts and disputes
against the same balance, under READ COMMITTED read-then-write, READ COMMITTED with
`FOR UPDATE`, SERIALIZABLE with retry, and SERIALIZABLE with `FOR UPDATE` (what the phases
actually run). Anomalies are counted from the data afterwards: over-refunds, lost updates,
payouts that spent money a dispute had taken, and balance drift. Throughput, latency and
retries per 100 operations are published with them. Results pending.
([isolation.md](docs/design/isolation.md))

**4. Model-based testing.** Random sequences of API operations run against a plain-Ruby
reference model and the real system side by side, with every invariant checked after every
step and failures shrunk to a short replay script. It found one real bug so far (below).
Results pending. ([model-testing.md](docs/design/model-testing.md))

**5. Reconciliation under injected discrepancies.** A simulated month of settlement files with
missing, duplicated, mismatched, late and unknown lines injected, scored against the
simulator's manifest: discrepancies detected by type, false exceptions, and explainability
before and after resolving them. Results pending.
([reconciliation.md](docs/design/reconciliation.md),
[results/exp5-reconciliation/README.md](results/exp5-reconciliation/README.md))

**6. Webhook delivery under hostile endpoints.** A hundred endpoints, some failing, some
hanging past the timeout and one flapping, delivered through a single FIFO queue and through
per-endpoint isolation, with worker processes killed at random in one run. It reports the
healthy endpoints' time to delivery at p50 and p99, completeness, and the duplicate rate.
Results pending. ([results/exp6-webhooks/README.md](results/exp6-webhooks/README.md),
[webhooks.md](docs/design/webhooks.md))

**7. Code quality, measured.** Branch coverage on `lib/`, mutation score from mutant on the
ledger, idempotency and money core, and every surviving mutant killed or explained as
equivalent. The mutation harness is on its own branch. Results pending.

**8. Throughput, and the system end to end.** Open-loop load at fixed rates against `confirm`,
latency measured from the intended send time so coordinated omission does not hide the tail,
with the machine labelled. This is here for honesty, not as a headline: Ruby on a laptop will not
impress anyone with raw throughput. The second half, RiskGate's test month replayed through
`confirm`, is not on this branch. Results pending. ([loadgen.md](docs/design/loadgen.md))

**9. RiskGate fails.** RiskGate is killed or frozen mid-run, and the experiment counts the
payments that went through unchecked (during the outage and in the tail after it), and checks
that the risk step's latency stays bounded by the deadline. The client-level runs so far found
the tail after a kill is about one breaker cool-down. Results pending.
([risk-integration.md](docs/design/risk-integration.md))

## Areas

Payments, idempotency and the retry storm are linked from the sections above:
[payments](docs/design/payments.md) (the state machine as a table, the outbox, refunds),
[idempotency and crash recovery](docs/design/idempotency.md), and
[experiment 1, the retry storm](docs/design/storm.md).

- [Internal interfaces](docs/design/interfaces.md): the contracts between the parts.
- [Ledger](docs/design/ledger.md): accounts, the money-flow table, policy choices, and how the database enforces double entry and append-only.
- [API](docs/design/api.md): request handling, errors, auth, and date-based versioning. The changelog is generated into [docs/api-changelog.md](docs/api-changelog.md).
- [Webhook security](docs/design/webhook-security.md): signatures, secret rotation, test vectors shared with the Go verifier, and the SSRF-safe egress path.
- [Webhook delivery](docs/design/webhooks.md): endpoints, the outbox dispatcher, the SKIP LOCKED queue with leases, at-least-once semantics, retries, and per-endpoint isolation.
- [Disputes and the notification feed](docs/design/disputes.md): reading the acquirer's feed exactly once in effect, and the dispute lifecycle.
- [Settlement and reconciliation](docs/design/reconciliation.md): matching settlement files against the ledger, the typed exceptions, and how an operator resolves them.
- [Acquirer simulator](docs/design/sim.md): the simulated card acquirer, how it drops responses after committing, and why the client separates Unknown from Unavailable.
- [Client library](docs/design/client.md): the Ruby client, and why it reuses one idempotency key across every retry of a call.
- [bin/explain](docs/design/explain.md): a readable trace of every ledger entry behind a payment, refund, dispute or payout.
- [Code quality](docs/design/quality.md): mutation testing with one database per mutant job, the coverage gates, and every surviving mutant explained.
- [Load generator](docs/design/loadgen.md): open-loop load at fixed rates, latency from the intended send time (coordinated omission), scenarios and rate sweeps.
- [Experiment 2, crash matrix](docs/design/crash-matrix.md): killing the server at every recovery point of every registered flow, recovering, and checking the outcome against an uninterrupted request.
- [RiskGate integration](docs/design/risk-integration.md): the deadline, keep-alive pool and circuit breaker, fail-open and what it costs, review holds on payouts, and where the risk step sits in confirm.
- [Balances and payouts](docs/design/payouts.md): availability after the settlement delay, payouts as atomic phases around the bank call, risk-review holds, and negative balances.
- [Scheduler](docs/design/scheduler.md): the one clock-driven worker, the order of its sweeps (expiry, the acquirer's notifications and settlement files, availability, payouts, the completer, the reaper) and why a failing step doesn't stop the others.
- [Isolation](docs/design/isolation.md): experiment 3, READ COMMITTED read-then-write against `FOR UPDATE` against SERIALIZABLE with retry, the anomalies each allows, and what ships where.
- [Replay through RiskGate](docs/design/replay.md): experiment 8, RiskGate's test month through the API under no checks, the model alone and model plus rules, with disputes, the assumed 15.00 USD fee, and what is real and what is simulated.
- [Model-based testing](docs/design/model-testing.md): experiment 4. A reference model of the domain, random operation sequences checked against the ledger and the API after every step, shrinking to a replay script, and a planted-bug demo.

## Testing

- [Wall-clock assertions](docs/design/testing-timing.md): why deadline specs have a load-tolerant form that always runs and a strict `:timing` form for `CLEARINGHOUSE_STRICT_TIMING=1`.

## Bugs the harness caught

Each entry in `docs/bugs/` says what broke, which test or experiment caught it, and the fix
commit. They are the real ones. Several were caught before the broken code was ever
committed, and the entry says so.

| Entry | What broke | Caught by | Fix |
|---|---|---|---|
| [ledger-hash-default-fetch](docs/bugs/ledger-hash-default-fetch.md) | Every posting raised `KeyError`: `Hash#fetch` ignores `Hash.new(0)`'s default | first run of `spec/ledger/posting_spec.rb` (20 failures) | `fetch(key, 0)` on plain hashes, in a7e2b43 |
| [ledger-same-code-two-currencies](docs/bugs/ledger-same-code-two-currencies.md) | A validation rule would have refused valid multi-currency settlement batches | `spec/ledger/posting_spec.rb`, a balanced JPY and KWD posting to the same codes | rule dropped; the composite foreign key enforces the real invariant, in a7e2b43 |
| [payments-jsonb-key-order](docs/bugs/payments-jsonb-key-order.md) | jsonb reordered keys in `last_payment_error`, metadata and event data | `spec/payments/payment_intent_spec.rb`, the fixture round trip | `json` columns, in 753f0ca |
| [payments-struct-with-enum](docs/bugs/payments-struct-with-enum.md) | Every change to an intent raised `KeyError`: `T::Struct#with` cannot round-trip a `T::Enum` prop | `spec/payments/payment_intent_spec.rb`, the first test that changed an intent | `PaymentIntent#copy`, in 753f0ca |
| [payments-concurrent-refunds-exhausted](docs/bugs/payments-concurrent-refunds-exhausted.md) | Concurrent refunds of one payment ran out of serialization retries and returned 500 | `spec/api/refunds_spec.rb` under load, then reproduced with 16 refunds | an advisory-lock turnstile before the phase, and exhaustion as a retryable 409, in 97d8424 |
| [risk-fractional-score](docs/bugs/risk-fractional-score.md) | A fractional `risk_score` made the RiskGate client raise instead of failing open | `spec/risk/assessment_spec.rb`, "refuses a fractional score" | check the class as well as the range, in 616f84a |
| [webhooks-dispatcher-cluster-xmin](docs/bugs/webhooks-dispatcher-cluster-xmin.md) | The dispatcher cursor stalled on any open transaction in any database on the cluster | `spec/webhooks/dispatcher_spec.rb`, stuck behind another test's `DROP DATABASE` | wait on this database's writers to `events` via `pg_locks`, in ac91458 |
| [loadgen-late-timer](docs/bugs/loadgen-late-timer.md) | Timer wake-up lateness added about 1 ms to every latency sample at low rates | the first smoke run of `bin/loadtest` (send delay fell as the rate rose) | sleep until 1 ms before the send, then spin, in 542ebb5 |
| [model-settlement-fee-over-gross](docs/bugs/model-settlement-fee-over-gross.md) | A payment smaller than the acquirer's fee produced a negative cash entry and could never be settled | experiment 4, `bin/model-test --sut ledger --seed 1`, shrunk from 56 steps to 5 | `Flows.settlement` credits cash for the difference, in 8e5a49a |
| [settlement-exp5-scorer-double-injection](docs/bugs/settlement-exp5-scorer-double-injection.md) | Experiment 5's scorer assumed one discrepancy per line, and miscounted a line deferred twice | `spec/experiments/reconciliation_month_spec.rb`, failing on one run in two | scorer rules for repeated `late`, `missing_then_arrived` and `not_observable`, in the experiment's first commit |
