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
| processing | risk_blocked | requires_payment_method | |
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
is every `(status, event)` the table does not list (37 of 48), and
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

## Operations as steps

Each mutating endpoint is a short list of steps in `lib/clearinghouse/payments/`. A step
whose name ends in `!` is local database work that runs in one transaction. The acquirer
call sits between two of them and is never inside a transaction, so no database lock is
held while the network is slow.

| operation | steps |
|---|---|
| create | `Create.create!` (intent + `payment_intent.created`) |
| confirm | `Confirm.lock!` (to processing, attempt + 1), `authorize`, `record_authorization!`, `apply_approval!` |
| capture | `Capture.check!`, `request`, `record!` |
| cancel | `Cancel.check!`, `void` (only with an authorization to release), `record!` |

`Payments::Flows` runs these steps as the atomic phases of idempotent flows. Each step commits
in a SERIALIZABLE transaction together with the recovery point it reaches, and each acquirer
call sits between two of them, so any stopped request can be resumed from the key row.
See `idempotency.md`. (The first version ran the steps in plain transactions, one after
another, with nothing to resume from.)

### Confirm

1. `lock!` locks the row, asks the table for `confirm`, bumps `attempt`, and moves the intent
   to `processing`. `attempt` is the only thing that changes the acquirer's idempotency
   key (`pi_...:authorize:<attempt>`), so it is bumped once per confirmation and never on a
   retry of the same one.
2. `authorize` calls the acquirer. Automatic capture sends `capture: true`, so one call
   moves the money.
3. `record_authorization!` stores a definite answer. A decline ends the attempt: back to
   `requires_payment_method`, `last_payment_error` set, the payment method cleared as
   Stripe does, and `payment_intent.payment_failed` emitted. The response is a 402
   `card_error`.
4. `apply_approval!` applies an approval: `requires_capture` with `amount_capturable`
   (manual) or `succeeded` with the capture posted to the ledger (automatic).

An `Unknown` or `Unavailable` answer is neither. The intent stays in `processing` and the
caller gets a 503 `acquirer_unavailable`, which never marks the payment failed:
`pm_card_timeout` really did charge the card. The retry asks the acquirer what happened
under the attempt's key (`idempotency.md`, "The ambiguous foreign call").

Between `lock!` and the authorization, the flow asks RiskGate (`Confirm.assess_risk`, with no
transaction open) and stores the verdict in its own phase (`Confirm.record_risk!`). A `block`
ends the attempt like a decline (`risk_blocked` in the table: back to
`requires_payment_method`, `last_payment_error.code = payment_blocked`,
`payment_intent.payment_failed`, 402 `risk_error`) before the acquirer hears of it. A
`review` proceeds, and the capture transaction opens a payout hold for what was captured
(`Risk::Step.hold_on_capture!` in `Support.post_capture!`). An app built without a RiskGate
client skips the check and leaves `risk` null. See `risk-integration.md`.

### What reaches the ledger

Only a capture moves money. It posts `Ledger::Flows.capture` under the intent's id with our
fee from the merchant's `FeeSchedule`, $20.00 at 2.9% + 30 cents being $0.88 fee and
$19.12 to the merchant's pending balance. In the same transaction it calls
`Payments::Seams.schedule_availability` with the net and the date the funds become
available (`payout_delay_days` after capture). That is an empty seam today. The payouts
work fills it with `Balances::Availability.schedule!`, so captured money stays in pending
until then. Authorizations, declines and cancels post nothing, and the tests assert so.

A partial capture posts what was captured, not what was authorized.

An amount whose fee would exceed it (under 31 cents at the default rate) is refused at
create and at capture (`amount_too_small`), since the merchant's share cannot be negative.

### Authorization expiry

`capture` refuses an expired authorization (`payment_intent_authorization_expired`) without
writing anything. `Payments::Expiry.sweep!` cancels every `requires_capture` intent whose
`authorization_expires_at` has passed on the injected clock
(`Dependencies#authorization_ttl_days`, default 7), one transaction each, rechecking under
the row lock so a capture that commits first wins. It sends no void. The authorization lapses
at the acquirer by itself, and nothing here can capture a canceled intent, so a void would
only add a foreign call that can fail. Its event has no request, because no request caused it.

### Tests against the real acquirer

The payments specs talk to the real simulator over HTTP: one in-process Puma on an ephemeral
port for the run, its books reset per example. `AcquirerSpec::ScriptedClient` is the real
client with faults on demand. It can report `Unknown` after the acquirer really committed
(a dropped response), or `Unavailable` without sending. So the acquirer's own records
(`authorizations`, `captured`) are the ground truth in every assertion about charges, not
a fake written to agree with the code under test.

The illegal-transition table is also sent over HTTP: every request-triggered illegal pair
(confirm, capture, cancel) against an intent in that status, asserting the typed error, the
same ledger, balance and event row counts before and after, the intent row unchanged, and
no call to the acquirer.

## Refunds

`POST /v1/refunds` takes `payment_intent`, an optional `amount` (everything not yet refunded
by default), `reason` and `metadata`. Its steps:

1. `Refunds.reserve!` locks the intent, asks the table for `refund` (only `succeeded` has
   it), checks the amount against `amount_received - amount_refunded`, inserts the refund
   `pending`, and adds its amount to the intent's `amount_refunded`. This is the reservation.
2. `Refunds.request` sends the acquirer refund with the refund's own id as the idempotency key.
3. `Refunds.record!`: approved means `succeeded`, the refund flow posted under the `re_` id
   (merchant available to `refund_clearing`, with a description naming the payment for
   `bin/explain`), and `charge.refunded` with the charge. Refused means `failed` with the
   acquirer's code as `failure_reason`, the reservation released, and `charge.refund.updated`.

The reservation is the concurrency design. The intent is locked only for the reservation, not
across the acquirer call, so a payment can have several refunds in flight. Because each one
reserves under the row lock before the acquirer hears about it, in-flight refunds can never add
up to more than was captured. `payment_intents_refunds_within_received` backs that up in the
database. A spec fires ten concurrent 300-cent refunds at a 2000-cent payment. Six succeed,
four are refused, and the acquirer's own books show exactly 1800 refunded.

A refund whose acquirer call is unanswered stays `pending` with its reservation held. That is
the safe direction: the acquirer may have refunded, so the money must not be offered to
another refund.

## Balance

`GET /v1/balance` reads `merchant:<id>:available` and `:pending` from the ledger for every
currency the merchant has accounts in (zero USD when there are none), in Stripe's shape. It
is a read of `account_balances` with no lock. The payout work takes `balance_for_update`
when it needs one.
