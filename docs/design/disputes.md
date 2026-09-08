# Disputes and the acquirer's notification feed

Code: `lib/clearinghouse/acquirer/notification_poller.rb`, `bin/poller`,
`lib/clearinghouse/disputes/`, `lib/clearinghouse/api/routes/disputes.rb`. Schema:
`db/migrations/20260926100000_acquirer_notifications.rb`, `20260926110000_disputes.rb`.

## The feed

Everything the acquirer tells us after the fact (a dispute opened or closed, a payout paid
or failed) arrives on one feed, `GET /notifications?after=<cursor>`, visible once the
request's `Sim-Time` reaches the notification's due time (`docs/design/sim.md`).
`Acquirer::NotificationPoller` reads it and hands each notification to the handler
registered for its type. Disputes register `dispute.opened` and `dispute.closed`; payouts
register `payout.paid` and `payout.failed` (`Settlement.notification_handlers` is where
`bin/poller` collects them).

### Exactly once, from two at-least-once parts

The feed can hand us the same notification twice: we crashed before saving the cursor, two
pollers run at once, or someone rewinds the cursor to replay. So each notification is
handled in **one database transaction** that does three things:

1. inserts the notification id into `processed_notifications` (`ON CONFLICT DO NOTHING`),
2. runs the handler, which writes its own effects (a dispute row, ledger postings, an event),
3. moves the consumer's cursor in `acquirer_cursors`.

The insert is the gate. If it inserted nothing, the notification's effects already
committed, and the handler is skipped. If the transaction rolls back for any reason, none of
the three happened and the next poll sees the notification again. Two pollers racing on the
same notification serialize on the primary key: the second blocks until the first commits,
then its insert conflicts and it skips. The cursor alone would be enough for a single
poller; the table is what makes a second one (or a replay) harmless. A cursor that moves
backwards because of a race costs one extra fetch and nothing else.

This is the same idea as the outbox on the sending side: the record that something was done
lives in the same transaction as the doing.

### Order, and what happens to a notification nobody handles

Notifications are handled strictly in feed order, and the first failure stops the poll with
the cursor on the last one that committed. A `dispute.closed` must never be applied before
its `dispute.opened`. A notification whose type has no handler also stops the poll, before
anything is written for it. I considered parking unknown types and moving on, but a skipped
`payout.failed` is money the merchant never gets back, and "park and replay later" needs a
second mechanism that would itself need testing. Stopping is loud and loses nothing: the
poller logs the error and retries the same notification on the next poll, so registering the
handler is all it takes to resume.

### Recovery points

`NotificationPoller::RECOVERY_POINTS` lists where a crash can land:

| point | state | what recovery does |
|---|---|---|
| `notification_fetched` | read from the feed, nothing written | the next poll fetches it again and applies it |
| `effects_written` | everything written, not committed | the transaction dies with the process; same as above |
| `committed` | committed, next notification not started | the cursor already moved; the next poll starts after it |

`spec/settlement/notification_poller_spec.rb` crashes at each point (the hook raises, which
aborts the open transaction exactly as a dead process would) and checks that after a
restart every notification's effects exist exactly once, the ledger invariants hold, and
`processed_notifications` has one row each. The spec iterates the constant, so a new point
cannot be skipped. When the idempotency framework's crash hook (`CLEARINGHOUSE_CRASH_AT`)
lands, `crash_hook:` is where it plugs in.

### Running it

```
bin/poller                 # poll every 5 seconds
bin/poller --once          # one poll; exit status 1 if the acquirer was unreachable or a handler failed
```

## Disputes

A dispute (a chargeback) is started by the cardholder's bank, never by the merchant or by
us. In the simulator, capturing a `pm_card_disputeFraudulent` charge schedules one
`dispute_after_days` later. It reaches us as a `dispute.opened` notification and is decided
by a `dispute.closed` with `outcome: won | lost`.

| What happens | Status | Ledger (`dp_` flow) | Event |
|---|---|---|---|
| `dispute.opened` | `needs_response` | merchant available -> dispute_clearing (amount), merchant available -> dispute_fee_revenue (fee) | `charge.dispute.created` |
| acquirer's `dispute` settlement line | | dispute_clearing -> cash (the reconciler posts it) | |
| `dispute.closed`, won | `won` | dispute_clearing -> merchant available (amount; the fee is kept) | `charge.dispute.closed` |
| acquirer's `dispute_reversal` line | | cash -> dispute_clearing (the reconciler posts it) | |
| `dispute.closed`, lost | `lost` | nothing: the merchant paid at open, and the `dispute` line already cleared it | `charge.dispute.closed` |
| merchant accepts (`POST /v1/disputes/:id/close`) | `lost` | nothing, for the same reason | `charge.dispute.closed` |

Each row is one database transaction: the dispute row, its ledger posting and its event
commit together. The two notification rows run inside the poller's transaction, so the
dispute, the `processed_notifications` row and the cursor move together too. Descriptions
name the payment (`dispute dp_... opened on pi_...`), the convention `bin/explain` uses to
show a dispute under its payment.

The event object is the contract with RiskGate, which reads dispute events as fraud labels:
`{id, object: "dispute", payment_intent, amount, currency, reason, status}`, plus `fee`,
`created` and `livemode`. Those seven fields are also in the versioning engine's protected
list, so no version change can rewrite them.

### Decisions

**The ledger time is the acquirer's time.** Every posting is dated at the notification's
due time (`created_at`), not when we polled. The reconciler expects the `dispute` line
`settlement_lag_days` after the dispute opened, and a poller that was down for a day must
not move that date.

**The dispute can be bigger than what is left of the payment.** The simulator fixes the
disputed amount at capture, so a charge refunded $40 of $100 can still be disputed for the
full $100. This is on purpose: cardholders do dispute refunded charges. We debit the full
disputed amount, because that is what the acquirer takes from us. The merchant's evidence
(the refund) is how they win it back. The spec in `disputes_spec.rb` walks through it.

**Negative balances are carried.** Opening a dispute can take the merchant's available
balance below zero (the $100 payment above leaves -$18.20 after the dispute and its fee).
The card network has already decided, so refusing the dispute is not an option. Payouts are
blocked while available is not positive, and later captures pay it down
(`docs/design/ledger.md`).

**The fee, per currency.** 15.00 USD, and in other currencies a round local price near that,
not converted at a rate (FX is out of scope). `Disputes::FeePolicy::DEFAULT_FEES` prices every
currency in the exponent table, in its own minor units (2200 JPY, 4.600 KWD), and a currency
without a price raises rather than charge nothing. The fee is kept when the dispute is won:
it pays for handling the dispute, which happened either way.

**Accepting the loss.** Stripe calls it closing the dispute. Nothing moves in the ledger.
Accepting twice returns the same dispute, so a retry is harmless, and a won dispute cannot
be accepted (`dispute_already_closed`). The simulator has no endpoint for "the merchant
accepts", so the acquirer is not told; its dispute stays open until it rules. When it does:
a `lost` ruling changes nothing; a `won` ruling still returns the money, because the
acquirer's ruling is what moves cash and its `dispute_reversal` line will arrive whatever we
recorded. A ruling that contradicts an earlier ruling (lost, then won) raises and stops the
poller: that is a bug somewhere, and guessing would put money in the wrong place.

**Unknown payments stop the feed.** A `dispute.opened` whose acquirer reference matches no
payment raises `UnknownPaymentError` before writing anything. The reconciler's exceptions
are the place such money should surface for an operator; until then, stopping is the honest
option (see "Order" above).

### Recovery points

`Disputes::RECOVERY_POINTS` lists each flow's points. `dispute.opened` and `dispute.closed`
run inside the poller's transaction, so theirs are the poller's three. The merchant's accept
has `dispute_locked`, `effects_written` and `committed`, and recovery is the client retrying
the request. `spec/settlement/disputes_recovery_spec.rb` crashes at all nine and checks one
dispute row, one posting per step, one event per state change, and the ledger invariants.

### Seams (what is not on main yet)

- `PaymentLookup#by_acquirer_reference` finds the PaymentIntent behind an acquirer reference.
  The payments work owns `payment_intents.acquirer_reference`; its implementation plugs in
  here. Specs use `StandInPaymentLookup` in `spec/support/settlement.rb`.
- `Disputes::EventSink#emit!` has the shape of `Events.emit!`, the outbox. Specs use
  `RecordingEvents`, which records an event only when its transaction commits.
- `Api::Dependencies#disputes` is nil until both exist, and the close endpoint answers
  `api_error` until then. `Settlement.notification_handlers(disputes:)` registers the
  handlers for `bin/poller`.
- `disputes.payment_intent` gets a foreign key once `payment_intents` exists.
