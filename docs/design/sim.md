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
