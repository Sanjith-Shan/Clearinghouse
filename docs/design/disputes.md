# Disputes and the acquirer's notification feed

Code: `lib/clearinghouse/acquirer/notification_poller.rb`, `bin/poller`. Schema:
`db/migrations/20260926100000_acquirer_notifications.rb`.

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
