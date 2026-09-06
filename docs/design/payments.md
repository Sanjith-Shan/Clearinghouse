# Payments

Code: `lib/clearinghouse/payments/`, `lib/clearinghouse/events.rb`. Schema:
`db/migrations/20260924100000_payment_intents.rb`, `20260924100100_events.rb`.

PaymentIntents are the Stripe-shaped object a merchant creates, confirms with a test
payment method, and captures. This note covers the state machine, the schema, and the
outbox. Idempotency and crash recovery have their own note (`idempotency.md`).

## The state machine is a table

`Payments::StateMachine::TABLE` is the whole machine: rows of `(from, event, to, guard)`.

| from | event | to | guard |
|---|---|---|---|
| requires_payment_method | confirm | processing | |
| requires_confirmation | confirm | processing | |
| processing | authorization_approved | requires_capture | capture_method manual |
| processing | authorization_approved | succeeded | capture_method automatic |
| processing | authorization_declined | requires_payment_method | |
| requires_capture | capture | succeeded | |
| requires_payment_method | cancel | canceled | |
| requires_confirmation | cancel | canceled | |
| requires_capture | cancel | canceled | |
| requires_capture | authorization_expired | canceled | |
| succeeded | refund | succeeded | |

Services never compare statuses themselves. They call
`StateMachine.transition(from, event, capture_method:)`, which returns the new status or
raises `UnexpectedStateError`, and it raises before anything has been written. The API
turns that into `invalid_request_error` with code `payment_intent_unexpected_state` and a
message that lists the statuses that would have worked, generated from the table.

Because the machine is data, the tests are generated from it. `StateMachine.illegal_pairs`
is every `(status, event)` the table does not list (32 of 42), and
`spec/payments/state_machine_spec.rb` asserts each one is refused. A row added to the table
changes the list automatically. There is also a test
that the table is deterministic (for any capture method, at most one row matches a
`(from, event)`) and one that every status is reachable.

Decisions:

- **Guards are named, not lambdas.** The only fork is the approval: automatic capture
  goes straight to `succeeded`. A `Guard` enum with an exhaustive `case` keeps the table
  printable and comparable, which a proc would not be.
- **Refund is a row even though it doesn't change the status.** It is how "refund an
  intent that has not succeeded" becomes an illegal transition like the others, and is
  generated into the tests along with them.
- **No cancel from `processing`.** The spec's diagram draws one. I left it out, as Stripe
  does. `processing` means an authorization is in flight whose outcome may not be known
  yet (the acquirer timed out). A cancel there would race the confirm that owns the
  authorization, and a void sent before the authorization is resolved can arrive at the
  acquirer first. The confirm finishes, or the completer finishes it, and the intent can be
  canceled from wherever it lands.
- **Partial capture is the capture row.** `amount_to_capture` below the authorized amount
  captures that much and releases the rest. The acquirer allows one capture per
  authorization, as card networks do, so the intent goes to `succeeded` either way.
- **Expiry is its own event** (`authorization_expired`) that lands in `canceled` with
  `cancellation_reason: automatic`, the value Stripe uses. It has its own event so a log line
  or an event consumer can tell a merchant's cancel from a lapsed authorization.

## Schema

`payment_intents` holds the amounts as integer minor units in three columns that must
agree with the status, and the database checks that they do, as a backstop in the
same spirit as the ledger's triggers:

- `amount_capturable` is non-zero only in `requires_capture`, and `requires_capture` always
  has an authorization (acquirer reference and expiry).
- `amount_received` (captured) is non-zero only in `succeeded`, and `succeeded` always has
  some.
- `amount_refunded <= amount_received`. Refunds reserve against `amount_refunded` before
  the acquirer is asked, so this one constraint stops two concurrent refunds from over-refunding
  even if the Ruby check above it were wrong.

`lock_version` is bumped on every write and checked in the `UPDATE`'s `WHERE`. Inside a
phase that holds the row lock it can never fail. It is there so a code path that forgot the
lock fails loudly instead of writing over someone else's change.

Object-valued columns (`metadata`, `last_payment_error`, `risk_fields`, `risk`) are `json`,
not `jsonb`. jsonb stores keys in its own order (shortest first), so a merchant's metadata
would come back reordered. The first version used jsonb, and the fixture round-trip test
caught it: `last_payment_error` came back as `code, message, decline_code`.

There is no `charges` table. An intent has at most one successful authorization, and
everything a charge reports is already on the intent. `latest_charge` is a `ch_` id
generated at authorization, and `PaymentIntent#charge_to_api` builds the object.

The app role gets `SELECT, INSERT, UPDATE` on intents and never `DELETE`.

## The outbox

`events` rows are written by `Events.emit!` inside the database transaction that makes the
state change. The row then commits if and only if the change does, which is the spec's
"the outbox is in the phase". `data` is the object at the latest API version, and
delivery renders it per endpoint with `Versioning.render_event`. `seq` is a `bigserial` for
the dispatcher to scan in order. It is assigned at insert, not at commit, so a scan by seq
has to allow for a lower number committing after a higher one it has already seen.
`emit!` refuses a type that is not in `Events::TYPES`, since an event with a misspelled type
is one nobody subscribes to. Events are insert-only for the app role.
