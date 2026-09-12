# Webhook delivery

How an event written by a payment becomes a signed POST to every endpoint that wants it,
at least once, at the endpoint's API version, without one bad endpoint slowing down the
rest. Signatures and the SSRF guard are in [webhook-security.md](webhook-security.md); this
note is everything around them.

Sources that shaped it:

- Stripe's webhook docs, https://docs.stripe.com/webhooks, sections "Event delivery
  behaviors" (automatic retries "for up to three days with an exponential back off",
  manual retries, event ordering, API versioning) and "Handle duplicate events".
- The PostgreSQL `SELECT` docs on `SKIP LOCKED`: "any selected rows that cannot be
  immediately locked are skipped. Skipping locked rows provides an inconsistent view of
  the data, so this is not suitable for general purpose work, but can be used to avoid
  lock contention with multiple consumers accessing a queue-like table."
- Marc Brooker, *Exponential Backoff And Jitter*, AWS Architecture Blog (2015), for full
  jitter.

## Shape

```
payments transaction ──INSERT──> events (outbox, seq)
                                    │
                         bin/dispatcher: fan out, idempotent
                                    ▼
                          webhook_deliveries (the queue)
                                    │  claim: FOR UPDATE SKIP LOCKED + lease
                    bin/webhook-worker × N processes × M threads
                                    │  render at endpoint version, sign
                                    ▼
                          SafeHttp POST ──> merchant endpoint
                                    │
                             record: success / retry / failed,
                             breaker and endpoint health
```

Code: `lib/clearinghouse/webhooks/` (`endpoints.rb`, `dispatcher.rb`, `queue.rb`,
`worker.rb`, `worker_pool.rb`, `retry_policy.rb`, `circuit_breaker.rb`, `breakers.rb`,
`endpoint_health.rb`, `deliveries.rb`), routes in `lib/clearinghouse/api/routes/`.

## Endpoints

`webhook_endpoints (id we_..., merchant_id, url, enabled_events jsonb, api_version,
description, status, disabled_reason, secret, previous_secret, previous_secret_expires_at,
created_at, updated_at, deleted_at)` plus the failure-run and breaker columns below.

| Route | What it does |
|---|---|
| `POST /v1/webhook_endpoints` | `url`, `enabled_events[]` (`*` or known types), optional `api_version` (defaults to the merchant's pinned version) and `description`. Returns the secret, once. |
| `GET /v1/webhook_endpoints[/:id]` | Retrieve, list (newest first, `limit`, `starting_after`). |
| `POST /v1/webhook_endpoints/:id` | Change `url`, `enabled_events`, `description`, or `disabled`. |
| `DELETE /v1/webhook_endpoints/:id` | Soft delete. Pending deliveries fail with `endpoint_deleted`. |
| `POST /v1/webhook_endpoints/:id/roll_secret` | New secret; the old one keeps signing for `expires_in` seconds (0 to 86400, default 86400). |
| `GET /v1/events[/:id]` | The outbox, rendered at the caller's version. |
| `POST /v1/events/:id/retry` | Manual resend to `webhook_endpoint`. |

- **The URL is checked when it is registered or changed**, with `SafeHttp#pin`: parse,
  resolve, check every address. A blocked URL is a 400 `url_invalid` naming the reason. A
  DNS failure is accepted, because a merchant may register before their DNS is live, and
  every delivery checks again anyway.
- **The API version is pinned at creation.** Changing a merchant's version later does not
  change what its existing endpoints receive. Stripe likewise structures what it sends to
  an event destination "for the event destination's specified version".
- **Secrets are stored in plaintext.** They cannot be hashed like API keys, because signing
  needs the secret itself. A real system would encrypt them with a data key from a KMS
  (envelope encryption) and decrypt only in the delivery worker; this is a simulation and
  does not. Rotation is `SecretRotation` from the security work, persisted as two columns;
  a roll locks the row, so two concurrent rolls cannot both keep "the previous secret" and
  silently drop one.
- **Deletes are soft** so delivery history still names its endpoint. The app role has
  `UPDATE` on endpoints but no `DELETE`.
- At most 16 endpoints per merchant, Stripe's limit, enforced under a per-merchant
  advisory lock so two concurrent creates cannot both see 15.

## The dispatcher

`bin/dispatcher` turns each event into one `webhook_deliveries` row per endpoint that is
subscribed to it: same merchant, enabled, not deleted, `enabled_events` containing `*` or
the type, and created no later than the event (an endpoint does not receive history from
before it existed). Subscriptions are evaluated at dispatch time. `UNIQUE (event_id,
endpoint_id)` with `ON CONFLICT DO NOTHING` makes fan-out idempotent: scanning an event
twice, restarting from zero, or running two dispatchers never creates a second delivery.

**The cursor.** The dispatcher walks `events` by `seq` from a stored cursor. The trap is
that `seq` is assigned at insert, not at commit. If transaction A draws seq 10, B draws 11
and commits first, a dispatcher that sees 11 and moves its cursor there will never look at
10 again once A commits. So:

1. Every pass fans out everything visible above the cursor. Delivery never waits for the
   cursor.
2. After the scan it records a **barrier**: the highest seq it saw, and the virtual
   transaction ids of every transaction then holding a write lock (`RowExclusiveLock`) on
   `events`, from `pg_locks`, filtered to this database.
3. A later pass moves the cursor to the barrier once none of those transactions is still
   running (none holds its own `virtualxid` lock). The check runs before that pass's scan,
   so anything that committed in the meantime is fanned out in the same pass that moves
   the cursor past it.

This works because an `INSERT` locks its table when it opens it, before it evaluates the
`seq` default, and keeps the lock until the transaction ends. Any transaction that drew a
seq at or below the barrier and had not committed by the scan was holding the lock when the
barrier was taken. It assumes the sequence has `CACHE 1` (the `bigserial` default), so seqs
are drawn in order across sessions, and that nobody uses two-phase commit on `events`.

A long-running writer holds the cursor back for as long as it runs. That costs rescanning
the window above the cursor on every pass, not correctness.

The first version compared against `pg_snapshot_xmin`. Transaction ids are cluster-wide,
so a transaction in any database held the cursor back; a stuck `DROP DATABASE` in another
test database stalled it for ten minutes. That is
[docs/bugs/webhooks-dispatcher-cluster-xmin.md](../bugs/webhooks-dispatcher-cluster-xmin.md).

Each pass also fails pending deliveries whose retry window has passed without a live
lease (`retry_window_elapsed`), which is how deliveries stuck behind an open breaker end.

## The queue

**Why Postgres, and why SKIP LOCKED.** The outbox, the deliveries and the endpoints are
already in Postgres, and a delivery row is created in the same kind of short transaction
as everything else. A separate broker would need its own outbox relay to stay consistent
with the database, and would hide the queue from SQL. `FOR UPDATE SKIP LOCKED` is what
makes a table usable as a queue: a claimer that meets a row another claimer is locking
skips it instead of waiting, so any number of workers claim in parallel without
serialising on the head of the queue and without ever getting the same row.

**Claim, send, record.** Three steps, and only the first and last touch the database:

1. **Claim**, one short transaction: pick a due row with `FOR UPDATE SKIP LOCKED`, set
   `lease_token`, `lease_expires_at = now + lease`, `attempts = attempts + 1`, commit. The
   row lock lasts milliseconds.
2. **Send** with no transaction open: load the event and the endpoint, render, sign, POST.
3. **Record**, one short transaction: success, a retry time, or failure, plus the
   endpoint's breaker and health.

Holding a transaction open across the HTTP request would pin a connection per in-flight
delivery and hold row locks for up to the full timeout. The lease replaces the lock: a
delivery is in flight while its lease is live, and a worker that dies leaves a lease that
expires, after which any worker can claim the row again. The crashed attempt still counts
as an attempt, so a delivery that crashes its worker every time still runs out of retries.

**Lease rules at record time.**

- A 2xx is recorded whoever holds the lease now, and clears the lease. The endpoint has
  the event; that is the fact.
- A failure is recorded only by the worker whose token is still on the row. If the lease
  expired and another worker took over, the late failure changes nothing, because the new
  owner is in charge of the retry schedule.

**Leases use the Clock**, like everything else, which makes them testable with a test
clock (a spec leases, advances 59 s, cannot claim, advances 1 s, can). The lease (60 s
by default) must be longer than a delivery can take in wall time, which is SafeHttp's
total timeout (10 s by default) plus two short transactions. Under a clock that runs
faster than wall time, the lease must be scaled to match.

## Delivery semantics: at least once

Every committed event reaches every subscribed, healthy endpoint **at least once**. Some
reach it twice. The window is real and cannot be closed from the sending side: a worker
can crash (or lose its database connection, or be `kill -9`ed) after the endpoint has
answered 200 and before the record transaction commits. The lease expires and another
worker sends the event again. A spec does exactly this and sees the server receive it
twice.

**Why exactly-once over HTTP is not on offer.** Exactly-once delivery would need the
endpoint's side effect and our "delivered" record to commit atomically, and they live in
two systems that share no transaction. Recording before sending turns the crash window
into a lost event instead of a duplicate, which is worse. Waiting longer, retrying the
record, or asking the endpoint afterwards all leave the same window somewhere. Timeouts
make it worse in the other direction too: a request that timed out on our side may have
been processed on theirs. What can be had is exactly-once *processing*, and that is the
receiver's job: **consumers must dedupe on the event id**. Stripe's docs say the same:
"Webhook endpoints might occasionally receive the same event more than once. You can
guard against duplicated event receipts by logging the event IDs you've processed, and
then not processing already-logged events." RiskGate does this.

Other things consumers should assume, as with Stripe:

- **No ordering.** Retries and per-endpoint isolation reorder deliveries. `created` is in
  whole seconds and does not order events either.
- **A new signature per attempt.** Each attempt is signed at the clock's time with the
  secrets active then, so a retry after a secret roll carries the new secret.
- **Rendering per endpoint.** The stored event is the latest shape. Each attempt renders
  it with `Versioning.render_event(Events.envelope(row), endpoint.api_version)`, so two
  endpoints on different versions receive two different bodies for one event id (a spec
  checks `amount_captured` on a 2026-01-01 endpoint and `amount_received` on 2026-09-01).

**Manual resend** (`POST /v1/events/:id/retry`) behaves like Stripe's: it does not cancel
automatic retries, it is refused for a disabled endpoint, and it reaches back 30 days. A
delivery still pending is made due now and keeps its retry window. One that already
succeeded or failed gets exactly one more attempt (its deadline is set to now), not three
more days of retries.

## Retries

`RetryPolicy`: full jitter, `delay = uniform(0, min(12 h, 60 s * 2^(n-1)))` after the n-th
failed attempt, and no attempt after `created_at + 3 days`, when the delivery is marked
failed. The randomness is an injected `Random`, so a seeded spec checks the exact
schedule end to end against a real server that always answers 503. Over 2000 seeds a
delivery that always fails is attempted 16 to 30 times, median 21.

Without jitter, every delivery that failed during one outage would retry at the same
instants, and the endpoint that just came back would take the whole backlog at once. Full
jitter spreads them over the whole interval.

- `Blocked` (the URL now resolves somewhere internal) fails at once and is not retried:
  it will be just as blocked next time.
- An exception on our side (a render bug) is retried on the same schedule and is not held
  against the endpoint's health.
- Timeouts, connection failures, non-2xx statuses and redirects are retried.

## Disabling an endpoint that keeps failing

A **run** of failures starts at the first failure after a success and ends at the next
success, or at a quiet spell of more than a day with no attempts. When a run has lasted
**5 days**, the endpoint is disabled (`disabled_reason: failing_continuously`), its pending
deliveries fail with `endpoint_disabled`, and a `webhook_endpoint.disabled` event is
emitted in the same transaction. That event is fanned out like any other, so it reaches
the merchant's other endpoints.

Five days because the retry window is three: a single event can never disable an endpoint,
it takes steady traffic failing for longer than any one delivery is retried. Stripe's docs
give the retry window but no disabling threshold, so five is my choice. The quiet-spell
rule stops an endpoint that failed once last week and once today from counting as a week
of failure.

Stripe keeps retrying if an endpoint is disabled and re-enabled before the next retry.
Here disabling fails the pending deliveries at once; re-enabling does not bring them back,
and the merchant resends what they need.

## Per-endpoint isolation

The failure this prevents: an endpoint that accepts connections and never answers holds
a worker for the full read timeout on every attempt. With a plain queue, enough of those
at the head of the queue and every worker is waiting on the same dead endpoint while
healthy endpoints' deliveries sit behind them. Three defences, all enforced in Postgres so
they hold across every worker process.

**1. In-flight cap per endpoint** (default 4, `--max-in-flight`). A delivery is in flight
while it holds a live lease. A claim is one call to the PL/pgSQL function
`webhook_claim_isolated`, which:

1. Picks candidate endpoints: those with due, unleased deliveries that are neither open
   nor at their cap, oldest due delivery first. No locks; this is a hint.
2. For each candidate: locks the endpoint row `FOR UPDATE SKIP LOCKED` (if another claimer
   has it, moves on to the next endpoint, never waits), checks the breaker, counts the
   endpoint's live leases in a fresh statement, and leases one delivery only if under the
   cap. The first to succeed is returned.

Claims for one endpoint take turns on its row lock, and each commits its lease before
releasing the lock, so each sees every lease before it (in PL/pgSQL each statement of a
volatile function takes a new snapshot under READ COMMITTED, so the count is taken after
the lock). The cap cannot race, across threads or processes. A spec runs twelve claimers
on two separate connection pools against one endpoint with a cap of 3 and gets exactly 3;
with the row lock removed from the function it gets 4.

*Why a function.* The first version did the same steps from Ruby: a candidate query, then
per endpoint `BEGIN`, lock, count, lease, `COMMIT`, five or six round trips per claim
where FIFO needs one. A trial run of experiment 6 with every endpoint healthy showed
isolation *slower* than FIFO (median time to delivery 3.6 s against 0.7 s), and
`exp/webhooks/claim_bench.rb`, which claims and completes 1500 deliveries with 32
threads and no HTTP, measured 62 and 83 claims a second for isolation against 245 and
386 for FIFO, on a machine where one Postgres round trip took about 3 ms (Docker on
macOS, other test suites running). Per-endpoint isolation that costs a factor of three
in throughput would lose to FIFO on any workload without a hostile endpoint in it. The
function runs the identical steps in one round trip. The one behavioural difference:
an endpoint row that was locked and then skipped (at its cap) stays locked until the
claim ends, milliseconds later, instead of being released at once. I have not re-run the
bench since the change; that and the experiment are to be re-run on a quiet machine.

*Why a row lock and a lease count, and not the alternatives.* A counter column
(`in_flight += 1` on claim, `-= 1` on record) is cheaper to read, but a worker killed
between the two leaks a slot forever, so it needs a repair job that is itself a lease
count. A transaction-scoped advisory lock keyed on the endpoint id would serialise claims
the same way; the row lock is used because the claim needs that row anyway (breaker
state, status), and locking what you read keeps it to one mechanism. Counting live leases
cannot leak: a dead worker's lease expires and stops counting.

**2. A circuit breaker per endpoint**, persisted on the endpoint row so every worker sees
the same state, and changed only under that row's lock.

| Parameter | Default | Why |
|---|---|---|
| Open after | 5 consecutive failures | Enough to not trip on one bad deploy blip; few enough that a dead endpoint costs at most a handful of timeouts. |
| First cool-down | 30 s | Then one probe. |
| Cool-down after a failed probe | doubles, up to 10 min | An endpoint down for a day is probed every ten minutes, not every thirty seconds. |
| Half-open | 1 in flight | Exactly one probe; its success closes the breaker. |
| Close | any success | A delivery claimed before the breaker opened that comes back 200 is as good a probe as any. |

While open, the endpoint is not claimed at all. Its deliveries use no worker time and
burn no retry attempts; if it stays down past their retry window, the dispatcher fails
them. Failures while already open (deliveries claimed before it opened) are counted but
do not push the retry time out.

**3. Short timeouts.** Connect 2 s, each read 5 s, the whole exchange 10 s
(`SafeHttp`'s defaults, flags on `bin/webhook-worker`). Stripe asks endpoints to "quickly
return a successful status code (2xx) before any complex logic that could cause a
timeout", and a sender that waits longer only rewards slow endpoints with more of its
workers.

**Fairness.** Candidates are ordered by their oldest due delivery, and SKIP LOCKED spreads
concurrent claimers over different endpoints, so an endpoint with a deep backlog gets at
most its cap while a quiet endpoint's single event goes out next.

**Cost.** The candidate query groups all due, unleased deliveries by endpoint on every
claim. With thousands of due rows that is a few milliseconds; with millions it would need
a per-endpoint "next due" column maintained on record, or a ready-endpoints table, so the
candidate scan is over endpoints rather than deliveries. I have not built that.

## The FIFO baseline

`FifoQueue` (`bin/webhook-worker --mode fifo`) is the queue from before isolation: one
queue, oldest event first, `FOR UPDATE SKIP LOCKED`, the same leases, retries, timeouts
and disabling, and no cap or breaker. It is correct, and it is what a first version of
this would look like. Experiment 6 runs the same workload against both. An integration
spec shows the difference in miniature: four workers, one hung endpoint with twelve
deliveries queued ahead of twelve healthy ones. Isolated: the hung endpoint gets two
attempts, its breaker opens, and the healthy twelve arrive in well under the time one hung
attempt takes. FIFO: all twelve hung attempts go first.

## Running it

```
bin/dispatcher --interval 0.1
bin/webhook-worker --threads 8                     # isolated, the default
bin/webhook-worker --threads 8 --mode fifo         # the baseline
```

`bin/webhook-worker` flags: `--max-in-flight`, `--breaker-threshold`, `--breaker-cooldown`,
`--breaker-max-cooldown`, `--lease`, `--connect-timeout`, `--read-timeout`,
`--total-timeout`, `--idle-sleep`, `--seed`, `--test-mode` (allow `http://localhost`),
`--log` (one JSON line per attempt and per breaker transition). TERM or INT finishes the
current deliveries and exits. Any number of worker processes and dispatchers can run;
they coordinate only through Postgres.

## What this does not do

- **No push from dispatcher to workers.** Idle workers poll every 50 ms. `LISTEN/NOTIFY`
  would cut idle latency and database load.
- **No per-endpoint adaptive concurrency.** The cap is one number for everyone. A
  high-volume merchant with a fast endpoint would want more.
- **Retries are per delivery**, so an endpoint with a thousand failed deliveries retries a
  thousand times over three days (behind its breaker). Stripe-style "process undelivered
  events" tooling for merchants is not built.
- **Delivery history** keeps only the last attempt's status, error and duration on the
  delivery row, not every attempt.
