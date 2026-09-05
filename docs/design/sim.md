# The acquirer simulator

`sim/` is a stand-in for the card acquirer: the company that talks to the card networks,
holds authorizations, moves captured money, and later sends settlement files and
disputes. It runs as its own process (`bin/sim`, Puma on port 4600) so that every call
Clearinghouse makes to it crosses a real TCP connection that can really fail. The
contract is in `docs/design/interfaces.md`; this note records why it is built the way it
is.

It is a simulation. There are no card numbers, only test tokens, and no real money.

## Shape

- `AcquirerSim::Simulator` holds the books: operations by idempotency key and
  authorizations by acquirer reference, in memory behind one mutex. Every decision about
  an outcome, and every state change, happens inside that lock.
- `AcquirerSim::App` is a Sinatra app that parses headers and bodies and renders what the
  simulator decided. No business rule lives in it.
- It depends on nothing in Clearinghouse except the pure value code: the currency
  exponent table, `Money`, and `FeeSchedule`'s half-even rounding (`sim/lib/acquirer_sim/shared.rb`
  loads those three files directly, never `lib/clearinghouse.rb`, which would pull in the
  database).

## Operations and their rules

`POST /authorize`, `/capture`, `/void` and `/refund` each commit one operation under the
request's `Idempotency-Key`.

- An authorization is **approved** or **declined** by its test token. `capture: true`
  captures the full amount in the same call.
- **One capture per authorization**, of at most the authorized amount. A partial capture
  releases the rest, which is what card networks do and what the PaymentIntent state
  machine assumes, so a second capture fails `already_captured` rather than adding up.
- **Refunds** may be partial and several, and never total more than was captured
  (`amount_exceeds_captured`, which also covers refunding an uncaptured authorization).
- **Void** releases an uncaptured authorization. Nothing can be captured after it, and it
  cannot undo a capture.
- Authorization expiry is Clearinghouse's rule, not the simulator's. The simulator only
  records `created_at` (the request's Sim-Time) so an expiry can be checked against it.

Two kinds of refusal, on purpose:

| Kind | Example | HTTP | Recorded under the key? |
|---|---|---|---|
| Malformed request | amount is a string, unknown test token, missing Sim-Time | 400 | No. The key stays unused |
| Business rule | capture more than authorized, refund past captured, unknown reference | 200 with `status: failed` and a `decline_code` | Yes |

A business-rule failure is an answer about money, so a retry must get the same answer
even if the state has since changed; it is stored like any other operation. A malformed
request never reached the books, so burning the key on it would only make the caller's
fix harder.

## Idempotency on the acquirer side

This is what Clearinghouse's recovery from an ambiguous timeout stands on (the spec's
"beyond the reference" point 1), so it is strict.

- The first request with a key commits and stores its operation.
- The same key with the same body returns the stored operation byte for byte, with
  `Idempotent-Replayed: true`, and changes nothing.
- The same key with a different body, or for a different operation type, is `409
  idempotency_key_mismatch`. The body is fingerprinted as SHA-256 of the operation type
  and canonical JSON (keys sorted at every depth), so field order does not matter.
- `GET /operations/:key` returns the stored operation or `404 not_found`. A 404 is a
  definite "nothing happened under this key", because commit and store are one step
  under the mutex.
- A test races 32 threads on one key and asserts one commit.

Ids are hashes of the idempotency key (`acq_` + 24 hex of SHA-256), not counters or random
draws. Concurrent requests therefore get the same ids whatever order they win the mutex
in, and a simulator restarted between test runs cannot hand an old reference to a new
payment unless Clearinghouse reuses a key, which its keys (derived from the payment
intent id and attempt number) never do.

## Counting charges for experiment 1

`GET /admin/operations` returns every operation and authorization, and
`charges_by_reference`: per client reference (the PaymentIntent id sent as `reference`),
how many authorizations exist, how many were approved, and how many **captured money**.
A `captured` above 1 is a double charge counted from the acquirer's own books, not from
Clearinghouse's. `?reference=pi_...` narrows it to one payment.

## Misbehaving on command

`POST /admin/config` sets the knobs, merging over the current config and refusing
anything malformed (a typo that silently did nothing would make an experiment measure the
wrong thing). `POST /admin/reset` returns to a freshly started process: empty books,
default config.

| Knob | Default | What it does |
|---|---|---|
| `seed` | 1 | Seeds the traffic RNG. Setting it restarts the stream |
| `latency_ms {p50, p99}` | 0, 0 | Real-time sleep before processing, drawn from a lognormal fitted through p50 and p99 (`sigma = ln(p99/p50) / 2.326`). Latency has a long right tail and is never negative, which a lognormal gives and a normal does not |
| `error_rate` | 0 | Share of requests answered `503 service_unavailable` **before** anything is committed |
| `drop_after_commit_rate` | 0 | Share of fresh mutating requests that commit and then hang up |

Every request draws exactly four numbers from the seeded RNG, whatever the config, so a
fixed seed and a fixed request sequence misbehave identically, and changing one knob does
not shift what the others draw. Latency and `error_rate` apply to the status query too;
drops apply only to fresh commits.

The latency sleep happens *before* the commit. That is what makes a client read timeout
honestly ambiguous: the client gives up, and the operation commits a moment later. A test
shows exactly that.

## Dropping the connection after commit

`pm_card_timeout`, and `drop_after_commit_rate` for any operation, commit the operation and
then take the socket from Puma with a Rack **full hijack** and close it without writing a
byte. The client sees the connection end with no response, which Net::HTTP reports as
`EOFError` (measured in `spec/sim/drop_connection_spec.rb`, against Puma on a real port).
A 500 would not do: a client can tell a 500 apart and act on it, and the whole point is a
response that never arrives. On a server without hijack support the simulator answers
500 rather than pretend it dropped.

Only the fresh commit is dropped. A retry under the same key, and the status query,
answer normally, so Clearinghouse can always find out what happened.

## Unknown versus Unavailable

`Clearinghouse::Acquirer::Client` (in `lib/clearinghouse/acquirer/`) sends `Sim-Time` from
a `Clearinghouse::Clock` and the `Idempotency-Key`, and maps every ending of a call to one
of four outcomes:

| Outcome | Meaning | Produced by |
|---|---|---|
| `Approved(operation)` | The acquirer did it | 200 with `approved` or `succeeded` |
| `Declined(code, operation)` | The acquirer answered no. Processed, no money moved | 200 with `declined` or `failed` |
| `Unknown(reason)` | The request was sent and no answer came back. It may have committed | read or write timeout, EOF, reset after connecting, any 5xx other than 503, an unreadable 200 |
| `Unavailable(reason)` | Definitely not processed | connection refused or connect timeout, 503 |

Getting the two failure outcomes the right way round is the whole point, because the two
possible mistakes cost very different amounts:

- Calling an Unavailable **Unknown** costs one status query. Clearinghouse asks the
  acquirer, gets `404 not_found`, and carries on.
- Calling an Unknown **Unavailable** can cost real money. If Clearinghouse reads it as
  "nothing happened" and fails the payment, the customer was charged and the merchant
  was told no. If it retries under a new attempt number, and therefore a new key, the
  card is charged twice.

So the client is conservative, and it draws the line by **phase, not by exception class**.
Each call opens its own connection. A failure while connecting means no byte of the
request left the process, so it is Unavailable. Any failure after the connection is up,
whether writing the request or waiting for the answer, is Unknown, even an
`ECONNRESET` that probably means the server never read the request, because from the
client there is no way to be sure. A test has a server accept the connection and close it
unread, and the client calls that Unknown.

The 503 case rests on the acquirer's contract: the simulator decides a 503 before it
touches the books, so a 503 means "refused, nothing done". A 500 carries no such promise
(it could be a crash halfway through a commit), so any 5xx other than 503 is Unknown.

`Net::HTTP` retries idempotent requests once by default. The client sets `max_retries = 0`,
since a silent retry would hide exactly the ambiguity this class exists to report. It
uses a fresh connection per call for the same reason: a pooled keep-alive connection that
the server has quietly closed fails on write, and telling that apart from a real
mid-request failure is guesswork.

For the status query (`lookup`), every transport failure is `Unavailable`, meaning "no
answer yet, ask again", because a GET has no side effect of its own. It never means
"nothing happened": only `NotFound` means that, and `NotFound` is only returned for the
simulator's own `{"error":"not_found"}`. A 404 from anywhere else (a wrong base URL, a
proxy) raises instead, since reading it as "never charged" is the dangerous direction
again. Malformed requests and reused keys raise `ProtocolError`: they are bugs in the
caller, not states of a payment.

Note what Unknown asks of the caller. Resending under the **same** key is always safe,
because the acquirer replays; the status query is for when Clearinghouse wants to decide
without resending, for example after a crash when it no longer knows what it sent.
This is the "ambiguous foreign call" from the spec, built on the acquirer-side
idempotency described in Stripe's idempotency post and Brandur Leach's
*Implementing Stripe-like Idempotency Keys in Postgres* (reading list 1 and 2).

## Disputes, payouts and the notification feed

Everything the acquirer says later, rather than in the response, goes on one feed,
`GET /notifications?after=<cursor>&limit=<n>`. A notification has a due time and is
visible only to a request whose `Sim-Time` has reached it. Nothing reads the wall clock.

- **Disputes.** Capturing a `pm_card_disputeFraudulent` authorization (in the authorize
  call with `capture: true`, or later with `/capture`) schedules a `fraudulent` dispute
  for the captured amount, opening `dispute_after_days` (default 7) after the capture.
  The amount is fixed at capture. A refund made before the dispute opens does not shrink
  it, because cardholders do dispute refunded charges and Clearinghouse has to handle
  that rather than have the simulator hide it. Once the dispute has opened, refunds on the
  charge fail `charge_disputed`, since the money is already in the dispute process.
  `POST /admin/disputes/:id/resolve {outcome: won | lost}` closes it, and `dispute.closed`
  is due at that request's Sim-Time. Resolving before it opens, twice, or with another
  outcome is refused.
- **Payouts.** `POST /payouts` is accepted (`succeeded`) at once, and `payout.paid` is due
  one simulated day later. **A payout whose amount in minor units ends in 13** (1013,
  $10.13, 113 yen) gets `payout.failed` with `failure_code: account_closed` instead. The
  rule is on the amount because tests choose payout amounts but not merchant ids, which
  Clearinghouse generates. It hits about 1% of random amounts, so a randomized test that
  does not know the rule will still meet failures now and then, which is intended. A
  model-based test can predict them from `AcquirerSim::Simulator.payout_fails?`.

### The cursor

The cursor is the part that needed thought. Notifications are created in one order but
fall due in another, and one can be created *after* a poll with a due time *before* that
poll. That happens when a caller whose test clock lags resolves a dispute. A cursor over
creation order skips notifications that fall due out of order. A cursor over due time
skips the late-created, early-due one. So the cursor is assigned when a poll first sees a
notification. Each poll stamps every newly visible notification with the next number, in
(due time, creation) order, and returns those past the caller's cursor. Every
notification gets exactly one cursor and cursors only grow, so a consumer that follows
`next_cursor` sees each notification exactly once. There is a test for the lagging-clock
case and one that follows the cursor across forty polls.

A notification that has been stamped stays visible to later polls whatever their
Sim-Time, even an earlier one. Visibility is sticky. The alternative, hiding it again from
a lagging caller, would let two consumers disagree about what has happened.

## Settlement files

`POST /settlement_files {date, inject}` returns the day's CSV. The client has
`settlement_file(date:, inject:)`. The unit underneath is a **movement**:

| Movement | When it happens | `amount` | `fee` |
|---|---|---|---|
| `capture` | the capture (or the authorize with `capture: true`) | +captured | acquirer fee |
| `refund` | the refund | -refunded | 0 |
| `dispute` | the dispute opens | -disputed | 0 |
| `dispute_reversal` | a dispute is won | +disputed | 0 |

Each settles `settlement_lag_days` (default 2) after the UTC date it happened. Cash
received is `amount - fee`. Refunds and disputes carry no acquirer fee: the capture's
fee is kept, and whether the merchant pays a chargeback fee is Clearinghouse's policy.

**The acquirer fee** defaults to 1.5% plus 10 minor units, computed in integer minor
units with `Clearinghouse::FeeSchedule`'s half-even rounding. 1.5% of 100 cents is 1.5,
which rounds to 2. 1.5% of 300 is 4.5, which rounds to 4. The fixed part is a count of
**minor units of the capture's own currency**: 10 cents, 10 fils (0.010 KWD), or 10 yen.
For a zero-decimal currency like JPY the minor unit is the whole yen, so the fee is whole
yen by construction and nothing fractional can exist. The trade-off is that 10 yen is worth
less than 10 cents. `fee: {fixed: {"default": 10, "jpy": 15}}` sets the fixed part per
currency when that matters. The fee is computed when the capture happens, so changing the
config later does not rewrite old lines.

**The rule the reconciler can rely on: every movement appears in exactly one file.** It
goes in the first file generated whose date is on or after its due date, or later if
`late` deferred it. It goes in no file at all if `missing` dropped it. A movement that
happens after its day's file was already generated arrives in the next one. That happens
when a caller with a lagging clock captures "yesterday". The manifest lists such lines
under `carried_over` with `injected_late: false`, so they are never mistaken for an
injected discrepancy. Files are frozen once generated. The same request returns the same
bytes, `GET /settlement_files/:date` re-reads them, and a request for the same date with
different injections is refused `409 settlement_file_exists`. A date the caller's Sim-Time
has not reached is refused too. A property test runs random traffic with random `missing`
and `late` injections, and checks that every movement is emitted exactly once minus the
dropped ones. I confirmed it fails when either half of the rule is broken.

The CSV is written without a CSV library. Every field is an id, an integer, a validated
currency code, a fixed type name or a date, so no field can hold a comma, a quote or a
newline. That also avoids depending on the `csv` gem, which leaves Ruby's default gems in
3.4.

### Injected discrepancies

`inject` is a list. Each item is either explicit, targeting a line in this file by
`acquirer_reference` (and `line_type` if the reference has several lines), or
`{random: N, seed, types}`.

| Type | What the file shows |
|---|---|
| `missing` | The line is absent, and the money never arrives in any file |
| `duplicate` | The same line (same `line_id` and `acquirer_reference`) twice |
| `amount_mismatch` | `amount` moved away from zero by `delta` (default 1 minor unit, the hardest to spot) |
| `fee_mismatch` | `fee` increased by `delta` |
| `late` | The line is moved `days` (default 1) later, and appears exactly once there with that file's `settled_on` |
| `unknown_payment` | A capture line for a reference that was never authorized, with ids in the same format as real ones, so a reconciler has to look the reference up rather than spot a prefix |

A line takes at most one discrepancy. An explicit target that is not in the file is `422
discrepancy_target_not_found`, and a line targeted twice is `422 discrepancy_conflict`.
Every injection is validated before anything changes. Random injection draws from its
own RNG (the item's `seed`, or the config seed plus the item's position). It never
touches the traffic stream. When every line is taken it falls back to `unknown_payment`.

**Ground truth** for scoring experiment 5 is at `GET /admin/settlement_files/:date/manifest`,
and the CSV response's `Settlement-Manifest` header links to it. It lists each
discrepancy with the line's identity, the expected and actual amount and fee, and
`deferred_to` for `late`. It also lists `carried_over`: lines settling after their due
date, flagged as injected or natural. The manifest is kept out of the CSV so a reconciler
cannot peek at it.

**Determinism.** Ids are hashes of stable inputs, lines are sorted by `line_id`, and
random injection is seeded. A test runs a month of mixed traffic in USD, JPY and KWD
(captures, partial captures, refunds, voids, declines, disputes won and lost) with two
random discrepancies a day, twice. It checks that all 31 files and manifests match byte
for byte, and that a different seed changes the discrepancies and not the money.

## Running it

```
bin/sim                      # Puma on 127.0.0.1:4600, one process, up to 16 threads
bin/sim --port 4601 --threads 32
curl -s -XPOST localhost:4600/admin/config -d '{"seed":7,"drop_after_commit_rate":0.05}'
```

Clearinghouse finds it through `CLEARINGHOUSE_ACQUIRER_URL`. The specs boot it in process
on an ephemeral port (`SimServer` in `spec/sim/sim_helper.rb`), and one spec boots `bin/sim`
as a subprocess.
