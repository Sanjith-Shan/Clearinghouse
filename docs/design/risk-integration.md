# Calling RiskGate during confirm

RiskGate is the fraud rules engine next door (a Go service, its own repo). Clearinghouse asks
it about every confirm attempt and acts on the answer. This note covers the Clearinghouse
side: the client, the policy, where the step sits in confirm, and the trade-offs. The wire
contract is in `interfaces.md`, "RiskGate".

Code: `lib/clearinghouse/risk/`. Fake server for tests and experiments:
`sim/fake_riskgate/`, `bin/fake-riskgate`.

## The policy

| RiskGate says | Confirm does | `risk` column |
|---|---|---|
| `allow` | proceeds | `{decision, score, reasons, assessment_id, ruleset_version}` |
| `review` | proceeds, and holds the merchant's payout of the captured funds | same |
| `block` | fails the intent with `risk_error` / `payment_blocked` (402). Nothing is posted to the ledger and nothing is sent to the acquirer | same |
| no usable answer | proceeds unchecked | `{decision: "risk_unavailable", reason}` |

`reason` is one of `timeout`, `breaker_open`, `http_status`, `malformed`, `connection`.
`Risk::Decision.apply` is this table and nothing else.

## Fail open, and what it costs

When RiskGate doesn't answer in time, the payment goes ahead as if RiskGate had said allow.
The alternative is failing closed: refuse the payment. That turns every RiskGate outage into
a payments outage. Every merchant loses all their revenue for as long as a service that
isn't in the money path is down. That is worse than the fraud a short outage lets through,
so Clearinghouse fails open.

The cost is real, and it has a number: **every payment confirmed while RiskGate was
unavailable went through unchecked.** During an outage that is roughly the confirm rate times
the outage length, plus the cool-down tail described under the breaker. A fraudster who can
knock RiskGate over (or who just gets lucky with timing) gets their payments through. Three
things keep this honest rather than hidden:

- Each of those payments says so on the intent (`risk.decision = risk_unavailable`, with the
  reason). They can be counted, and they can be re-scored after the fact. Re-scoring is not
  built yet.
- Experiment 9 (`bin/exp-risk-failure`) measures the unchecked count for a real outage
  instead of assuming it.
- The breaker makes unavailability cheap for the payment, not invisible. Its transitions
  are logged for the operator.

Where fail-closed would be right: a merchant or a payment class where fraud losses would
outweigh lost revenue (very high-value, easily resold goods). That would be a per-merchant
policy switch on top of this table. It isn't built, because nothing in this project needs it.

## Why review holds the payout instead of blocking

`review` means RiskGate isn't sure. Blocking an uncertain payment turns away a customer who
is probably legitimate, and the merchant loses the sale for certain. Letting it through and
**holding the merchant's payout of those funds** puts the risk where it belongs. The card is
charged and the customer is served. If the payment turns out to be fraud, the dispute
arrives while the money is still on the platform, so the dispute debit comes out of held
funds instead of pushing the merchant's balance negative, where the platform eats it. This is
the "safer payouts" idea: the risk decision gates when money *leaves*, not whether it comes
in.

The hold is opened when funds are captured, not at confirm, and for the amount captured.
There is nothing to hold until capture. A partial capture should hold only what moved, and a
declined authorization should leave no hold behind.

## The client

`Risk::Client#assess(request, attempt:)` returns an `Assessment` or an
`Unavailable(reason)`. It never raises for anything RiskGate or the network can do, because an
exception would turn a risk outage into a 500 on confirm. `docs/bugs/risk-fractional-score.md`
is a case where it did raise, before the first commit.

### One deadline over the whole exchange

The default deadline is 50 ms (`RISKGATE_DEADLINE_MS`). It covers connecting, sending the
request and reading the full response together. `Net::HTTP` can't do that. It has separate
open, write and read timeouts, and the read timeout applies to each socket read, so a server
that sends one byte every 40 ms keeps a 50 ms read timeout happy indefinitely. Wrapping
`Net::HTTP` in `Timeout.timeout` does bound it, but it does so by raising into the thread at
an arbitrary point, which can land inside the pool's bookkeeping. `Risk::Http` is instead a
small HTTP/1.1 client over non-blocking sockets. Every wait (`wait_writable` on connect and
send, `wait_readable` on read) gets whatever is left of one `Deadline` on the monotonic
clock. The overrun is bounded by one wake-up, not by another wait. `spec/risk/client_spec.rb`
checks this against a hanging server, a slow server, a server that drips a byte every 10 ms,
and an unroutable address.

Why 50 ms: it is the starting budget in the RiskGate spec, and the confirm path already
spends tens of milliseconds at the acquirer, so 50 ms is a real but tolerable addition to a
confirm's worst case. RiskGate's own latency experiment (its experiment 5) reports the
highest rate at which its p99 stays inside this deadline. If that p99 is well under 50 ms,
the deadline should come down, because the deadline is exactly what a bad minute costs every
payment before the breaker opens. `RiskGate-Deadline-Ms` sends the remaining budget, so
RiskGate can count its misses. RiskGate still finishes the work (the velocity update and
decision log need it), and that is its choice.

The one part the deadline cannot cover is name resolution: `getaddrinfo` blocks and takes no
timeout. The pool resolves `RISKGATE_URL`'s host once and keeps the address. RiskGate is
expected to be addressed by IP or by a name the hosts file answers. Only `http://` is
supported. A TLS handshake per new connection inside a 50 ms budget belongs to the network
layer (a sidecar or mesh), not to this client.

### Keep-alive pool

A TCP handshake is a real share of 50 ms at the tail, so connections are pooled
(`Http::Pool`, thread-safe, most-recently-used first, at most 16 idle, and dropped after 30 s
idle, which is shorter than RiskGate's 120 s server idle timeout so we close first). Before a
connection is reused, a non-blocking one-byte read checks that the server hasn't closed it. That still
leaves a race: the server closes the connection just after the check. So if a *reused*
connection fails before a single response byte arrives, the request is retried once on a
fresh connection within the same deadline. Resending is safe because the Idempotency-Key
makes a second copy a replay on RiskGate's side. That is a deliberate contrast with the
acquirer client, which opens a connection per call because it has no such guarantee
(`sim.md`).

### Circuit breaker

`Risk::CircuitBreaker`, one per process, shared by all threads:

- **Closed → open** on 5 consecutive failures, or on a failure rate of 50% or more over the
  last 10 s once at least 20 calls were seen. The run catches a hard outage fast. The rate
  catches a brownout where every other call times out, which never produces a long run.
- **Open**: every call returns `breaker_open` at once, with no network. A dead RiskGate
  costs a confirm microseconds instead of 50 ms, and it stops a thundering herd of retries
  against a service trying to come back.
- **Half-open** after a 2 s cool-down: exactly one caller gets a probe. The others are still
  refused while it is in flight. If the probe succeeds, the breaker closes with clean
  statistics. If it fails, the breaker opens again for another full cool-down.
- Permits carry a generation, so a slow call that started before a transition can't close
  the breaker or count twice when it returns.

What counts as a failure: timeouts, connection failures, malformed responses, 5xx, 408 and
429. Any other 4xx still fails open but does *not* count. A 400 means Clearinghouse sent
something RiskGate rejects (RiskGate is strict about unknown `risk_fields` keys), which is a
bug on our side. Opening the breaker wouldn't fix it and would hide it behind `breaker_open`.

The parameters trade two costs against each other. During an outage, each probe costs one
payment up to the deadline (only one at a time). After RiskGate recovers, payments stay
unchecked until the next probe, up to one cool-down. A shorter cool-down means more probe
cost during an outage and fewer unchecked payments after it. With a 50 ms deadline, a probe
every 2 s costs a negligible share of confirms, and 2 s of unchecked tail is small next to
any real outage. Experiment 9 measures both.

**The cool-down runs on a monotonic clock, not the simulated clock.** Clearinghouse's
`Clock` is simulated time: tests freeze it, and replays jump it days at a time. A breaker
timed by it would never cool down under a frozen test clock, and would cool down instantly
whenever a replay skipped ahead between two payments. The breaker protects a real process
reached over a real network, so it waits in real time. It is also not `Time.now`, which NTP
can step backwards. `Risk::Monotonic` wraps `CLOCK_MONOTONIC` and is injected, so tests move
it by hand (`Monotonic::Manual`) with no sleeps.

## Where the step sits in confirm

`Risk::Step.call(intent_attrs, attempt:, clock:)` is written to slot between the
`intent_locked` and `authorization_requested` recovery points in the payments flow:

1. `intent_locked` commits: the attempt is incremented and the intent is `processing`.
2. `Risk::Step.call` runs with **no database transaction open**. It is a network call of up
   to the deadline. Holding the intent's row lock, or a SERIALIZABLE snapshot, across it
   would add RiskGate's latency to every conflicting transaction.
3. The next phase's transaction stores `outcome.verdict.risk` in the intent's `risk` column.
   - On `Block`, that transaction fails the intent with `outcome.verdict.error` (last
     payment error `risk_error` / `payment_blocked`) and emits `payment_intent.payment_failed`.
     It posts nothing to the ledger, and the flow ends without calling the acquirer.
   - On `Proceed`, it writes the `authorization_requested` recovery point, and the flow goes
     on to the acquirer.
4. The capture transaction calls `Risk::Step.hold_on_capture!(db, risk:, merchant_id:,
   payment_intent_id:, amount_captured:, clock:)`. It opens a payout hold through
   `Risk.holds` if the stored decision is `review`.

**What a crash-resume relies on.** A crash between 2 and 3 leaves nothing stored. The
completer resumes at `intent_locked` and calls the step again with the same attempt, so with
the same `Idempotency-Key: <payment_id>:<attempt>`. Two properties are involved, and they do
different jobs:

- **Correctness rests on persist-before-act.** Nothing acts on a decision (no acquirer call,
  no failure, no hold) until the transaction that stores it commits. Whatever answer the
  resumed call gets, that answer is both the one stored and the one acted on. So a different
  answer on resume is harmless: RiskGate down the first time and up the second, or an
  idempotency entry lost in a RiskGate restart. Once `authorization_requested` commits, a
  resume never calls RiskGate again for that attempt.
- **RiskGate's dedupe protects RiskGate's features, not our correctness.** Assessing twice
  would count the payment twice in every velocity window. RiskGate stores the response per
  key and replays it (`Idempotent-Replayed: true`) without touching velocity state, so a
  retry is invisible to its features. The request body is a pure function of the intent
  (`created` is the intent's creation time, not the call time), which matters because
  RiskGate answers 422 to a reused key with a different body.

A new attempt (confirm again after a decline, with another card) has a new key and gets a
fresh assessment. That is right, because it is a different payment method.

## What is not wired yet

- The confirm flow is the payments area's. It calls `Step.call` and stores the verdict as
  above, and the end-to-end test (a block posts nothing and never reaches the simulator)
  belongs with it.
- Holds are the payouts area's. `Risk.holds` defaults to `Holds::Unwired`, which raises, so a
  review can't pass silently without its hold. Wiring it is
  `Risk.holds = Risk::Holds::Delegate.new(Balances::Holds)` at boot.

## RiskGate-side facts this relies on

Read from RiskGate's `internal/service` (assess.go, idempotency.go, snapshot.go):

- The idempotency store is in memory and included in RiskGate's snapshots, which run every
  5 s by default. After a `kill -9`, keys from the last few seconds are forgotten, so a
  retry of one of those payments is assessed (and velocity-counted) a second time. That is
  harmless for our correctness (see above), and it is a small feature skew on RiskGate's side.
- A retry that arrives while the original is still running waits for it. With our deadline
  that usually means the retry also times out and fails open. That is correct, but it counts
  as a breaker failure.
- `RiskGate-Deadline-Ms` is informational there. RiskGate finishes the work and counts the miss.
