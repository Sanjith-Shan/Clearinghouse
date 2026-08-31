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
