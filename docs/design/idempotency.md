# Idempotency and crash recovery

Code: `lib/clearinghouse/idempotency/` (`typed: strict`), the payments flows in
`lib/clearinghouse/payments/flows.rb`, and the schema in
`db/migrations/20260924110000_idempotency_keys.rb`.

The starting point is Brandur Leach, *Implementing Stripe-like Idempotency Keys in Postgres*
(2017), https://brandur.org/idempotency-keys, and Stripe's *Designing robust and predictable
APIs with idempotency* (2017), https://stripe.com/blog/idempotency (reading list items 1
and 2). The atomic phases, recovery points, completer and reaper come from Brandur's post
and its reference implementation, rocket-rides-atomic. I read the post and did not copy
the code. The last section says what Clearinghouse does beyond it.

## The contract

Every mutating endpoint (`POST /v1/payment_intents`, `.../confirm`, `.../capture`,
`.../cancel`, `POST /v1/refunds`, `POST /v1/payouts`, `POST /v1/payouts/:id/cancel`,
`POST /v1/reviews/:id/approve` and `.../reject`) accepts an `Idempotency-Key` header of 1 to
255 characters, scoped to the merchant.

| The key is | The API answers |
|---|---|
| new | runs the request |
| finished, same request | the stored response, byte for byte, same status and headers, plus `Idempotent-Replayed: true` and `Original-Request: <request id>`. Nothing runs |
| used with different parameters (finished or not) | `400 idempotency_error`, `idempotency_key_reused`, `Clearinghouse-Should-Retry: false` |
| held by a request that is still running | `409 idempotency_error`, `idempotency_key_in_use`, `Clearinghouse-Should-Retry: true`. It never waits and never runs the work a second time |
| held by a request that stopped (crash, or a retryable error) | resumes from its recovery point |
| finished more than 24 hours ago | forgotten: the key can be used again, for anything |

**What gets stored.** A response is stored once the request has started executing and
the outcome depends only on the request. That covers every 2xx and every 4xx that the same
request would get again: a decline, `payment_intent_unexpected_state`, a refund past what was
captured. Stripe does the same. Three kinds of error are not stored. The key is released, and a
retry runs the request again:

- errors found before the key is looked at (parameter errors, a bad key). The request never
  started, so there is nothing to protect.
- transient conflicts: `409 lock_timeout` (another request owns the PaymentIntent) and `429`.
  The same request can succeed a moment later.
- every 5xx, including `503 acquirer_unavailable`. The request stopped at a recovery point,
  and retrying resumes it there.

`Api::FlowRenderer#error_response` is that rule in code.

**Keys are optional.** A request without one has no replay protection. A retry is a new
request, and the state machine refuses it if the first one got anywhere (confirm on a
`processing` or `succeeded` intent is `payment_intent_unexpected_state`). So a keyless client
never pays twice, but it can see an error for a request that actually succeeded. The
server still records a keyless request under a generated key (`auto_<request id>`,
`client_supplied = false`), so if it stops halfway the completer can finish it. The client
just can't ask for the answer.

### The fingerprint

`Idempotency::Fingerprint` is SHA-256 (hex) of the canonical JSON of
`[METHOD, path, params]`. In it:

- **Method**, uppercased, and **path** as routed. The path carries the object id, so the
  same key sent to confirm a different intent, or to cancel instead of confirm, is refused.
- **Params**: the query string and body merged, as `api_params.raw` holds them. That
  includes `expand[]`, because it changes the response that is stored and replayed.

Not in it: **headers**. The merchant is already the key's scope, and
`Clearinghouse-Version` is left out on purpose. A retry that sends another version is still
the same payment, and it gets the stored response at the version first used, as Stripe does.

Canonical form: object keys sorted at every depth, arrays kept in order (order means something
in `expand[]`), no whitespace, and every scalar except null written as a string. The last rule
makes `amount=2000` (form) and `{"amount":2000}` (JSON) the same request, which is right
because the endpoint parses both to the same value. A spec replays a form request with a JSON
retry.

## Atomic phases

A request is a chain of **phases**. Each phase has an optional **foreign** step (a call to
another system: the acquirer, RiskGate), which runs outside any transaction, and an **atomic**
step, which runs in one `SERIALIZABLE` transaction. That same transaction moves the key's
`recovery_point` to the phase's `to`. So after any commit, the recovery point says exactly
which work is durable.

```ruby
Phase.new(from: 'authorization_requested', to: 'authorization_recorded',
          foreign: ->(run) { ask the acquirer },
          atomic: ->(run, db, answer) { record it, with its consequences })
```

`Flow#recovery_points` is generated from the phases, and `Flow#validate!` checks they chain
from `started` to `finished`, so no separate list can drift. A flow is a stateless object in
a `Registry`, and a key row stores the flow's name, its input and a small `flow_state`, so a
process that never saw the HTTP request can finish it.

**SERIALIZABLE with retry.** `Idempotency::Serializable.transaction` retries a
serialization failure or a deadlock (Postgres 40001 and 40P01; Sequel raises
`SerializationFailure` for both) up to 8 attempts. Between attempts it sleeps a random time in
`[0, min(0.25 s, 5 ms * 2^attempt)]` ("full jitter"), so requests that collided don't
collide again in lockstep. A retried attempt starts from the committed `flow_state`, not
from what the rolled-back attempt left in memory (a spec checks that). Phases never nest,
and the helper refuses to run inside a transaction, where Postgres would ignore the
isolation level and a retry would redo only half the work. A spec produces real write skew
between two threads and checks that SERIALIZABLE plus the retry keeps the limit. Experiment 3
(M4) measures what SERIALIZABLE costs.

**Running out of retries is a 409, not a 500.** When the conflict outlasts all 8 attempts,
`Serializable::ExhaustedError` reaches `App#run_flow`, which answers `409 lock_timeout` with
`Clearinghouse-Should-Retry: true`. Nothing of the losing phase committed and the lease was
given back, so the retry resumes where the request stopped. Before this, the error fell
through to the generic handler as a 500 (`docs/bugs/payments-concurrent-refunds-exhausted.md`).

**Hot rows take turns before the snapshot.** A `FOR UPDATE` inside a SERIALIZABLE
transaction queues writers on a row, but the waiter still aborts when it gets the lock,
because its snapshot predates the winner's commit (`isolation.md`). Sixteen refunds of one
payment all write the intent's `amount_refunded`, twice each, so the last in line could lose
more than 8 times in a row. A phase can name the object it writes (`Phase#queue_on`), and
the runner then takes a session-level advisory lock on that name, on the phase's own
connection, *before* `BEGIN` (`Idempotency::Turnstile`). Each such phase starts after the
previous one committed and does not conflict with it at all. The refund phases that reserve
and record queue on `payment_intent:<id>`. The lock covers only the atomic step, which
touches nothing but the database, and it dies with the connection if the process does.
The retries that remain in that workload are SSI's page-level conflicts between concurrent
inserts of different idempotency keys (the key's own first transaction). They are cheap and
spread out, and the 409 covers the rare request that exhausts them.

## Confirm, point by point

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
                      (or requires_capture)        │      seam, review hold, succeeded event (or
                                                   │      amount_capturable_updated)
                                                   │
 [finished]           response stored              │  tx: render at the request's version, store bytes,
                                                   │      release intent and key
 client ◀──────────── 200 + body ──────────────────┘
```

What a crash right after each commit leaves, and what the retry or the completer does:

| Crash after | Durable | Resume does |
|---|---|---|
| `started` | a leased key, nothing else | runs the whole request from the start |
| `intent_locked` | intent `processing`, attempt N, owned by the key | asks RiskGate again under `<pi>:N`. RiskGate replays its stored answer, so velocity isn't counted twice. Nothing has acted on a risk answer yet, so any answer is safe to act on |
| `risk_assessed` | the verdict | goes straight to the acquirer. RiskGate is never asked again for this attempt |
| `authorization_requested` | the promise that the acquirer may have been asked | **asks the acquirer** under `<pi>:authorize:N` and authorizes only if the answer is "nothing under that key" |
| `authorization_recorded` | the acquirer's answer | applies it: status, ledger, event |
| `ledger_posted` | the money | renders and stores the response |
| `finished` | the response | replays it |

A crash **before** a commit (inside the transaction) rolls that phase back, which leaves the
previous row of the table. The fault-injection hook can crash at either moment.

Capture, cancel and refund follow the same rules with fewer points:

| Flow | Recovery points |
|---|---|
| `payment_intent.create` | started, finished |
| `payment_intent.confirm` | started, intent_locked, risk_assessed, authorization_requested, authorization_recorded, ledger_posted, finished |
| `payment_intent.capture` | started, intent_locked, capture_requested, capture_recorded, finished |
| `payment_intent.cancel` | started, intent_locked, void_requested, canceled, finished |
| `refund.create` | started, refund_created, refund_requested, refund_recorded, finished |
| `review.reject` | started, refund_created, refund_requested, refund_recorded, finished (the refund's phases, after closing the review) |
| `review.approve` | started, finished |
| `payout.create` | started, balance_reserved, bank_requested, bank_recorded, finished (`Payouts::RECOVERY_POINTS`, `payouts.md`) |
| `payout.cancel` | started, finished |

Every acquirer or bank call happens in a phase that starts at a point named `*_requested`,
and that point is committed before the call (a registry spec checks it). The only other foreign call
is RiskGate's, from `intent_locked`, and re-asking RiskGate is safe for the reason above.
Capture fixes its amount in `flow_state` at `intent_locked`, so a resumed capture sends
exactly the amount the first run would have. Refund carries its `re_` id the same way.

## The ambiguous foreign call

The hardest case is the one Brandur's post leaves to Stripe's own idempotency: the acquirer
charged the card, and the response never arrived. `Acquirer::Client` reports that as
`Unknown` (connected, sent, no answer) and keeps it distinct from `Unavailable` (never sent,
or a 503 before anything was done). See `sim.md`, "Unknown versus Unavailable".

What Clearinghouse does:

1. **Every acquirer call carries a key derived from the payment, never a random one.**
   Authorization: `<pi>:authorize:<attempt>`. Capture: `<pi>:capture:<attempt>`. Void:
   `<pi>:void:<attempt>`. Refund: the `re_` id. Whoever resumes the request can compute
   the key the first run used without having seen that run.
2. **An unknown answer changes nothing.** The phase raises `503 acquirer_unavailable`
   before its transaction, so the key stays at `authorization_requested`, the intent stays
   `processing`, and nothing is failed. The lease is given back so the client's retry can
   go straight in. With a key, the response carries `Clearinghouse-Should-Retry: true`.
3. **Resuming at a `*_requested` point asks first.** `Flows.definite` calls
   `GET /operations/<key>`:
   - approved or declined: that is the answer, and it is recorded as if the original response
     had arrived. No second authorization is sent.
   - `NotFound`: the acquirer never committed anything under the key, so the phase sends
     the request now, under the same key.
   - no answer to the question either: another retryable 503, and nothing changes.

Resending under the same key would also be safe with this simulator, since it replays. Asking
first is still the better protocol. Resume never sends a mutation it can't show is needed.
A status query is a read, so the completer can repeat it on a schedule without an issuer
counting another authorization attempt. And the decision the resume makes (record this
answer, or send) is explicit and tested rather than hidden inside the acquirer's replay.
`spec/integration/payments/idempotency_spec.rb` covers each branch against the real simulator:
`pm_card_timeout`, a dropped response on a normal card, a request lost before sending
(lookup says `NotFound`, then it authorizes, still under attempt 1's key), a status query
that goes unanswered, a lost decline (resolved to the same 402), a lost capture and a lost
refund. The acquirer's books show exactly one charge or refund each time.

### What an attempt is

`attempt` counts confirmations of one PaymentIntent. It is incremented once, in the
`intent_locked` phase of a confirm request, and stored in the same transaction as the
recovery point. Consequences:

- **A retry of the same confirm** (same Idempotency-Key, or the completer) resumes past
  `intent_locked`, so it never increments again. Same attempt, same acquirer key. That's
  what makes a lost answer recoverable: the retry asks about, and if needed sends, the same
  authorization.
- **A new confirm after a decline** (`requires_payment_method`, a new card, and necessarily
  a new request, because the first key's answer is the stored 402) runs `intent_locked`
  again. That is attempt N + 1 with a new acquirer key and a new RiskGate key, because it
  is a new authorization of a different card. Reusing the old key would get the old
  decline back from the acquirer's replay, or a 409 mismatch for the new card.
- **A confirm without a key after an unknown answer** is a new request. It finds the intent
  `processing` and is refused, and it never increments the attempt. The first request's row
  (under its generated key) stays at `authorization_requested` until the completer finishes it.

## Leases, and one request per PaymentIntent

`locked_at` plus `lock_token` is a lease, 60 s by default
(`Dependencies#idempotency_lock_timeout`, `CLEARINGHOUSE_IDEMPOTENCY_LOCK_TIMEOUT`). It
must outlast the slowest foreign call, which is the acquirer's 5 s read timeout plus the
risk deadline. Every phase commit renews it, and every phase commit is conditional:
`UPDATE ... WHERE id = ? AND lock_token = ? AND recovery_point = ?`. If a runner stalls
past its lease and another request takes the key over (with a new token), the stalled one's
next commit updates zero rows and raises `LockLostError` inside its transaction, so its
work rolls back. The client sees 409 and the retry replays the winner's result. This is a
fencing token. rocket-rides has only `locked_at`, and a runner that outlived its lock there
could still commit.

The key protects one request. It doesn't stop two *different* requests from interleaving
on one PaymentIntent. A capture and a cancel of the same authorized intent would both pass
their checks, then one would capture at the acquirer and the other void. So confirm, capture
and cancel also take `payment_intents.locked_by` (the key's id) in their first phase, and
release it in the transaction that finishes them, whether they succeed or store an error.
Another request that finds the intent owned gets `409 lock_timeout` (Stripe's code for this).
That error is transient, so it is not stored against the key. If the owner crashes, the
completer finishes it and releases the intent. Refunds don't take the intent. They reserve
their amount under the row lock instead (`payments.md`), so several can be in flight at once.

## The completer and the reaper

`Idempotency::Completer` finishes requests nobody is finishing. A key is a candidate when it
is unfinished, nobody holds it (the lease expired, or the request gave it back after a
retryable error), and its last run is at least `grace` ago. `grace` defaults to the lock
timeout, and it leaves a client that was just told to retry time to do it itself. Each
candidate is resumed through `Runner#resume`, under exactly the lease rules a client retry
uses, so a completer and a client, or two completers, never run one key at once. The loser
gets `KeyInUseError` and the pass reports the key as busy. A key whose acquirer still doesn't
answer is reported as failed, stays where it is, and is tried again on the next pass.

The completer knows nothing about payments. It needs a registry (to find the key's flow) and
a resumer. `Api::Completion.resume` rebuilds the request's context from the row alone: the
merchant, the original request id (so events it emits carry the request that caused them),
the key if the client supplied one, and a renderer at the stored API version and `expand[]`.
The response it stores is then exactly what the client's retry replays.

`Idempotency::Reaper.run` deletes finished keys older than 24 hours on the injected clock. It
never deletes an unfinished key, however old. Each one is a request the completer still owes an
ending, and its row is the only record of how far it got. The reaper counts them (`stuck`) for
an operator instead. A finished key past its 24 hours that the reaper hasn't reached yet is
treated as gone by the next request that uses it, so the contract doesn't depend on the
reaper's schedule. Each deleted key makes Postgres clear `payment_intents.locked_by`
(`ON DELETE SET NULL`), which is why that column has an index
(docs/bugs/idempotency-reaper-fk-seq-scan.md).

`bin/completer` runs, on every tick, the authorization expiry sweep, a completer pass and a
reaper pass, and prints one JSON line with what each did. `--once` does a single tick, and
`--interval`, `--grace` and `--limit` tune it. It is configured like the server
(`Dependencies.from_env`). `bin/scheduler` (`scheduler.md`) runs the same passes along with
the availability and payout sweeps, and is what a deployment runs.

## Fault injection

The runner calls `Dependencies#crash_hook` at every recovery point, twice: just before the
phase's transaction commits and right after. `CrashHook.from_env` arms it from
`CLEARINGHOUSE_CRASH_AT=<flow>:<point>[:before_commit]`, for example
`payment_intent.confirm:authorization_requested`, and it then calls `Process.exit!(86)` at
that one point. `exit!` skips ensure blocks and at_exit handlers, which is as close to a
power cut as a process can do to itself. A crash inside the transaction dies with the
connection, and Postgres rolls the phase back.

It can't fire in production. `from_env` returns the frozen `DISARMED` hook unless
`CLEARINGHOUSE_ENV` is `test` or `experiment`, and `Armed` refuses to be built outside those,
so a stray `CLEARINGHOUSE_CRASH_AT` does nothing. The environment is read once, when the
dependencies are built at boot. Nothing can arm the hook in a running process.

The names are exactly `Registry#crash_points`: every recovery point of every registered flow,
at both moments. Today that's 38 points across 9 flows, 76 crash points. A harness that
iterates over the registry covers a new flow or point without being told about it.
`spec/idempotency/crash_hook_spec.rb` does this in process for a toy flow: it crashes at each
point, resumes, and checks the result is identical to a clean run and every phase ran exactly
once. Experiment 2 does it with real processes for the payments flows.

## What goes beyond rocket-rides

- **The ambiguous call is resolved by asking, not by trusting the remote replay**, with
  derived acquirer keys, an attempt model that separates a retry from a new attempt, and
  `Unknown` kept apart from `Unavailable` all the way from the socket to the API response.
- **Fencing tokens** on every phase commit, so a stalled runner can't commit over its
  successor.
- **Keyless requests are recoverable** too. They get a generated key that only the completer
  uses.
- **Per-object ownership across phases** (`locked_by`), which a per-key lock alone can't give.
- **The outbox is in the phase.** Every event is written in the transaction of the state
  change it reports, so crash-resume can't lose one or emit one twice.
- **Serialization retries are bounded and jittered**, and a retried phase starts from
  committed state.
- **Byte-for-byte replay at the original API version**, with the version and `expand[]`
  stored so the completer renders exactly what the original request would have.
- **Recovery points are generated and enumerable**, so the crash experiment covers every
  point of every flow from the registry. Adding a flow adds its points to the experiment.
