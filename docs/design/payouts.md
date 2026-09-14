# Balances and payouts

Code: `lib/clearinghouse/balances/`. Schema: `db/migrations/20260925*`.
The ledger entries used here are rows of the money-flow table in `docs/design/ledger.md`.

This note covers what happens to a merchant's money after capture: when it becomes
available, and the rules that decide when it may leave.

## Availability

A capture credits the merchant's **pending** account. The money becomes **available**, and
so eligible for a payout, `payout_delay_days` after the capture (a merchant setting,
default 2, stored on `merchants`).

`scheduled_availabilities` has one row per captured payment: `flow_id` (the `pi_`),
merchant, net amount, currency, `available_on`, and once released, `released_at`,
`released_to` and the id of the ledger transaction that released it.

- **Scheduling is part of the capture.** The payments area calls
  `Availability.schedule!(db, flow_id:, merchant_id:, net:, available_on:, clock:)` inside
  the capture's transaction, next to the capture's ledger posting. The capture and its
  schedule commit together or not at all, so there is never pending money with no release
  scheduled, or a release for a capture that rolled back. `schedule!` is idempotent on
  `flow_id` (same terms return the existing row, different terms raise `ConflictError`),
  because a capture phase retried after a crash may call it again.
- **`available_on` is the start of a UTC day**, `Availability.available_on_for(db,
  merchant_id:, captured_at:)`. Stripe's `available_on` is a date, and a merchant reading
  a statement expects everything captured on one day to become available together.
- **The sweep**, `Availability.release_due!(db, clock:)`, releases every row whose
  `available_on` has passed. It posts `Ledger::Flows.funds_available` (debit merchant
  pending, credit merchant available) under the payment's flow id, dated at
  `available_on` rather than when the sweep happened to run.

### Why the sweep can't release twice

Each batch is one database transaction that claims due rows with
`SELECT ... WHERE released_at IS NULL ... FOR UPDATE SKIP LOCKED`, posts one ledger
transaction per row, and sets `released_at` on the row. The posting and the mark commit
together. That gives three properties, each with a test in
`spec/balances/availability_spec.rb`:

- **A crash mid-batch loses nothing and doubles nothing.** The test makes the third
  `Ledger.post!` of a batch raise. No row is marked, no balance moved, and the next sweep
  releases all five rows exactly once.
- **Concurrent sweeps split the work.** Four threads sweep 40 due rows at once with a
  batch size of 3. Every row is released exactly once across all of them, one ledger
  transaction per payment, and the balances add up.
- **A sweep never waits on another.** A second test holds two rows locked in an open
  transaction and runs a sweep. It releases the other rows immediately and leaves the
  locked two, and the next sweep picks those up.

The mark update also re-checks `released_at IS NULL` and raises if it changed nothing. With
the row locked that cannot happen. The check is there so that if it ever did, the result
would be an exception rather than a second release.

`SKIP LOCKED` over plain `FOR UPDATE` is about throughput, not correctness. With plain
`FOR UPDATE` a second sweep would wait on the first's rows and then find them released
(the `released_at IS NULL` filter is re-checked after the wait under READ COMMITTED). It
would still be correct, just serialized.

### Alternatives considered

- **Release lazily at payout time** (compute "what should be available by now" when a
  payout is created, with no sweep). There is no scheduled state to keep, but then the
  ledger's available balance is wrong between the due time and the next payout, and
  everything that reads it (dashboards, the negative-balance check, the model tests) has
  to repeat the calculation. The ledger should say what is true.
- **One row per merchant and day** rather than per payment. There would be fewer rows, but
  a risk hold is per payment, so the sweep would have to split a day's total back into
  payments whenever one of them is under review.

## Payouts

Code: `lib/clearinghouse/payouts.rb` and `lib/clearinghouse/payouts/`. API:
`lib/clearinghouse/api/routes/payouts.rb`.

A payout moves money from the merchant's available balance to their bank. The ledger rows
are the last three of the money-flow table:

| Event | Debit | Credit | payout_clearing after |
|---|---|---|---|
| Payout created (`Flows.payout`) | merchant available | payout_clearing | amount |
| Bank paid it (`Flows.payout_paid`) | payout_clearing | cash | 0 |
| Bank failed it, or declined it (`Flows.payout_failed`) | payout_clearing | merchant available | 0 |
| Canceled before it was sent (`Ledger.reverse!` of the creation) | payout_clearing | merchant available | 0 |

Every payout flow (`po_...`) therefore ends with payout_clearing back at zero, and
`Ledger.explain` reports it as explained. The specs check that for paid, failed, declined
and canceled payouts, and run `Ledger::Invariants.check!` after every example.

Statuses follow Stripe's: `pending` (created, not yet accepted by the bank), `in_transit`
(the bank accepted it), then `paid`, `failed` or `canceled`. `arrival_date` is one day after
creation, which is when the simulator's bank answers.

### The API

| Endpoint | |
|---|---|
| `POST /v1/payouts` | `amount` (optional, default the whole available balance), `currency` (default `usd`), `description`, `metadata` |
| `GET /v1/payouts/:id` | |
| `GET /v1/payouts` | `limit` (1 to 100), `starting_after`, `status`. Newest first |
| `POST /v1/payouts/:id/cancel` | only while `pending` and not yet sent to the bank |

A payout the balance can't cover is a 400 `invalid_request_error` with code
`balance_insufficient` and `param: amount`. Cancel on a payout that has gone to the bank is
400 `payout_not_cancelable`.

`amount` is optional where Stripe requires it. "Pay me everything" is the common manual
payout, and computing "everything" on the client is a race: the balance can change between
reading it and asking for it. Here "everything" is read under the same lock that reserves it.

### Not overdrawing

`reserve!` reads the available balance with `Ledger.balance_for_update`, which locks the
merchant's `account_balances` row until the transaction ends. The check, the insert and
the posting then happen under that lock, so a second payout (or a dispute debiting the same
account) waits and then sees the lower balance. This is the READ COMMITTED plus
`FOR UPDATE` strategy from experiment 3. It works the same inside the idempotency
framework's SERIALIZABLE phases, where a conflicting pair would also be caught as a
serialization failure and retried.

`spec/payouts/payouts_spec.rb` runs 12 threads, each asking for $10.00, against $96.80
available, on real Postgres connections. Exactly 9 succeed, 3 get `balance_insufficient`,
$0.80 is left, and the simulator received exactly $90.00 of payouts. With
`balance_for_update` swapped for the unlocked `Ledger.balance`, I ran the test three
times, and each time all 12 payouts succeeded.

### Phases and recovery points

Creating a payout makes one foreign call, to the bank (the simulator's `POST /payouts`,
through `Acquirer::Client#payout`). As with the acquirer, that call can end in an
ambiguous way. The client returns `Unknown` when the request was sent but no answer came
back. The work is split into atomic phases around that call, in the shape of Brandur
Leach's recovery points (reading list 1):

```
Payouts::RECOVERY_POINTS = started -> balance_reserved -> bank_requested -> bank_recorded -> finished
```

| Phase (method) | From | To | Writes, in one DB transaction |
|---|---|---|---|
| `reserve!` | started | balance_reserved | lock the available balance, check it, insert the payout, post `Flows.payout`, emit `payout.created` |
| `request_bank!` | balance_reserved | bank_requested | fix the bank idempotency key (`<po id>:bank`) and commit it **before** the call |
| `call_bank` | bank_requested | (none) | the foreign call, outside any transaction |
| `record_bank!` | bank_requested | bank_recorded | Approved: `in_transit` plus the bank's reference. Declined: `failed`, post `Flows.payout_failed`, emit `payout.failed` |
| (framework) | bank_recorded | finished | store the response on the idempotency key |

`started` and `finished` belong to the idempotency key. The three in the middle are also
stored in `payouts.recovery_point`, so a payout can be resumed from its own row. `drive!`
runs whatever phases are left from that column, and `create!` is `reserve!` then `drive!`.

**The ambiguous call.** `Unknown` and `Unavailable` record nothing: the payout stays at
`bank_requested`. The next `drive!` sees `bank_requested` and **asks the bank first**
(`Acquirer::Client#lookup` with the same key). If the bank has an operation, that answer
is recorded. If it has `NotFound`, the payout is sent under the same key. If the lookup
itself is `Unavailable`, nothing changes and a later drive tries again. The key is
committed before the call, so every retry asks about the key that might have been used,
never a new one. A payout goes to the bank at most once (failure is terminal, and the
merchant makes a new payout), so one key per payout is one key per attempt.

**The completer seam.** Until the framework's completer exists,
`Payouts.resume_incomplete!(db, bank:, clock:)` finds pending payouts at `balance_reserved`
or `bank_requested` that have not been touched for 60 simulated seconds, and drives them.
Racing a live request is safe. Each phase re-checks the recovery point under the payout's
row lock, and the bank dedupes the key, so two drivers can at worst both ask the bank the
same question.

### The crash matrix

For experiment 2. Each row is a crash right after that point commits, and each row has a
spec in `spec/payouts/payouts_spec.rb` ("resuming after a crash or a lost answer"):

| Crash after | State left | Recovery | Checked |
|---|---|---|---|
| started | nothing written | the retry starts over | (no state) |
| balance_reserved | money in payout_clearing, nothing sent | resume sends it | one payout at the bank, `in_transit` |
| bank_requested, before the call | key committed, nothing sent | resume looks up the key, `NotFound`, sends | one payout at the bank |
| bank_requested, after the bank accepted | the bank has it, we don't know | resume looks up the key, finds it, records it, **does not call `payout` again** | `payout` not called, one payout at the bank |
| the response was lost (`Unknown`, via the simulator's `drop_after_commit_rate: 1`) | as above | as above | one payout at the bank, then paid and explained |
| bank unavailable (503, `error_rate: 1`) | nothing sent | resume retries while the lookup is refused, and sends once the bank is back | one payout at the bank |
| bank_recorded | `in_transit` | nothing left but the notification | the framework replays the stored response |

A notification can overtake a stuck request. If the bank's `payout.paid` arrives while the
payout is still at `bank_requested`, the handler applies it, takes the bank's reference from
the notification, and moves the payout to `bank_recorded`, so the resume has nothing left to
do. That case has a spec too.

### Plugging into the idempotency framework

The framework (payments area) runs each atomic phase in a SERIALIZABLE transaction that also
advances the key's recovery point, and resumes an expired key from that point. The mapping
is:

1. Register `payout` with the framework's recovery-point registry using
   `Payouts::RECOVERY_POINTS`, in that order, so experiment 2 enumerates them from code.
2. Phase `started`: call `Payouts.reserve!` inside the framework's phase transaction (it
   joins an open transaction) and store the payout id on the key. Next point
   `balance_reserved`.
3. Phase `balance_reserved`: `Payouts.request_bank!`. Next point `bank_requested`.
4. Foreign call: `Payouts.call_bank(bank, payout, resuming:)`, with `resuming` true when
   the key was *loaded* at `bank_requested` (a retry or the completer). That is what makes
   it ask before sending.
5. Phase `bank_requested`: `Payouts.record_bank!` with the outcome. On `Unknown` or
   `Unavailable` it changes nothing, and the framework should leave the key at
   `bank_requested` and return a 500 that says to retry (`Clearinghouse-Should-Retry: true`,
   since the request carried a key). Otherwise next point `bank_recorded`.
6. Phase `bank_recorded`: render `payout.to_api`, store the response, `finished`.
7. The crash hook: put `CLEARINGHOUSE_CRASH_AT` checks after each phase commits, and after
   `call_bank` returns but before `record_bank!`. That last one is the "bank accepted,
   answer lost" row above.

Once that is wired, `resume_incomplete!` is redundant for API-created payouts and should
only drive automatic ones, which have no key. The payout row keeps its own
`recovery_point` either way, because automatic payouts are created by a sweep and not by
a request.

### Bank notifications

`Payouts.handle_notification(db, notification, clock:)` applies `payout.paid` (payout_clearing
-> cash) and `payout.failed` (payout_clearing -> available, with the bank's `failure_code`).
The notification poller (disputes area) owns the cursor and calls this for each
notification of those types. Delivery is at least once, so the handler locks the payout
row and returns `:duplicate` if the payout is already in that state. It returns
`:unknown_payout` for a reference it doesn't know and `:ignored` for other types. A
notification that contradicts the record (paid after failed, paid for a canceled payout, a
different bank reference) raises `NotificationConflictError`. That is a bug on one side,
and skipping it would leave money in payout_clearing with nobody looking.

### Automatic payouts

`Payouts.run_scheduled!(db, bank:, clock:)` is the daily sweep. It pays each merchant on a
`daily` schedule, and each `weekly` one on Mondays (Stripe's default anchor), the whole
positive available balance in each currency. `manual` merchants are skipped. There is at
most one automatic payout per merchant, currency and UTC day. The scan skips balances that
already have one, `reserve!` re-checks under the balance lock, and a unique index
(`payouts_one_automatic_per_day`) is the backstop. A spec runs four schedulers at once and
gets one payout. Run it after `Availability.release_due!` so the day's newly available money
is included. Money released later the same day waits for the next day's payout.

### Cancel

A payout can be canceled while it is `pending` and has not been sent to the bank (recovery
point `balance_reserved`). The creation transaction is reversed with `Ledger.reverse!`, in
the same transaction that marks the payout canceled. Once `bank_requested` is committed the
bank may have the payout, and this bank has no cancel. So cancel covers payouts whose
request stopped before the bank call. With the bank call inline, that window is small.
If payouts were batched and sent by a sweep, as Stripe's are, it would be large.

I considered resetting a payout to `balance_reserved` when the bank answered `Unavailable`
(definitely not processed), to make it cancelable again. It is unsafe with two drivers. One
driver gets `Unavailable` and resets, while another has just sent under the same key and
gets `Approved`. That driver's record step then finds the recovery point moved and drops
the answer, and a cancel would return money the bank is paying out.

### Events

`payout.created`, `payout.paid`, `payout.failed` and `payout.canceled` are emitted in the
same transaction as the change they report, through `Balances::EventSink`. The events outbox
(`Events.emit!`, payments area) is not on main yet, so the default sink
(`Balances::DEFAULT_EVENTS`) drops them, and specs use a recording stand-in that also checks
each event is emitted inside a transaction. Wiring the outbox means changing
`DEFAULT_EVENTS` to an adapter that calls `Events.emit!`, and adding the types in
`Balances::EVENT_TYPES` to `Events::TYPES`.

## Risk-review holds ("safer payouts")

Code: `lib/clearinghouse/balances/holds.rb`, API `lib/clearinghouse/api/routes/reviews.rb`.

M6's rule is that a payment RiskGate answers `review` for goes through, but **the merchant's
payout of those funds waits until the review is closed**. A hold (`risk_holds`, one per
payment, ids `prv_` as Stripe's Reviews) does that with the merchant's third account,
`merchant:<id>:held`. Payouts only ever read and debit `available`, so there is no code path
from `held` to a bank. The rule is enforced by where the money sits, not by a filter
every payout query has to remember.

| Event | Debit | Credit |
|---|---|---|
| Funds due while under review (`Flows.funds_held`) | merchant pending | merchant held |
| Review opened after the funds were available (`Flows.funds_withheld`) | merchant available | merchant held |
| Review approved, or the rejecting refund posted (`Flows.hold_released`) | merchant held | merchant available |

These are posted under the payment's own flow (`pi_`), and no clearing account is involved.
The rows are also in the ledger's money-flow table.

### Lifecycle

- **Open.** The risk integration calls `Holds.open_hold!(db, flow_id:, merchant_id:, amount:,
  reason:, clock:)` when RiskGate says `review`. That is normally during confirm, before the
  capture has scheduled anything. When the availability sweep reaches the payment, it asks
  `Holds.withholds?` and posts pending -> held instead of pending -> available, recording the
  amount in `risk_holds.held_amount` in the same transaction. If the review opens after the
  money was already available, `open_hold!` moves it back (available -> held). That can take
  available negative if a payout already spent it, and then the negative-balance rules
  below apply.
- **Approve** (`close_hold!(decision: :approve)`, `POST /v1/reviews/:id/approve`). Whatever
  the hold has in held goes to available. If the sweep has not reached the payment yet,
  nothing moves now, and the sweep later releases straight to available.
- **Reject** (`close_hold!(decision: :reject)`, `POST /v1/reviews/:id/reject`). The payment is
  refunded through the `Balances::RefundRequester` seam, and **nothing is released**. The
  refund debits merchant available (the ledger's refund row), so the held money has to go
  back to available at the same moment, or the merchant would be charged twice. It
  can't go earlier, or a payout could pay out a payment we just called fraud. So the refund
  calls `Holds.release_after_refund!` in the transaction that posts its own entries, and
  the two postings cancel on `available`. Until that refund posts, `withholds?` stays true,
  so a sweep in between still sends the money to held.

`amount` on a hold is the payment amount under review, for display. The money actually held
is the payment's net, `held_amount`, which is what approve and release move.

### Races

Every path that touches one payment's money locks its `scheduled_availabilities` row first
and its `risk_holds` row second, in the same order as the sweep. So approve, reject,
open-after-release and release-after-refund each either run entirely before a sweep's
release of that payment or entirely after it, and none can deadlock with it. The database
also refuses the states a lost race would produce: an approved hold, or one whose refund
has posted, with money still counted as held (`CHECK`s on `risk_holds`).

Two specs cover it. A random one runs a sweep and four approvers over 16 reviewed payments
at once. In the deterministic one, the sweep pauses after deciding "held" while still
holding the availability lock. The approval has to wait for it, and afterwards the money is
in available and nothing is held. Removing the availability lock from the approve path made
the deterministic spec fail. The random spec passed with the same lock removed, because
the window is too narrow to hit by chance, and that is why the deterministic spec exists.

### Reviews API

| Endpoint | |
|---|---|
| `GET /v1/reviews` | `open` (true or false), `limit`, `starting_after` |
| `GET /v1/reviews/:id` | |
| `POST /v1/reviews/:id/approve` | |
| `POST /v1/reviews/:id/reject` | Clearinghouse's own. Stripe rejects by refunding the charge |

The object follows Stripe's Review: `payment_intent`, `open`, `opened_reason: "rule"`,
`closed_reason` (`approved` or `refunded_as_fraud`), plus `amount`, `currency` and
`reason`. Here `reason` is RiskGate's reason for the review, where Stripe's is a status
word. Closing a closed review is 400 `review_closed`. Events: `review.opened` and
`review.closed`.

### What the refund seam needs from payments

`Balances::DEFAULT_REFUNDS` is `UnwiredRefundRequester`, which raises
`RefundsNotWiredError`. A reject fails, and the review stays open, rather than closing
without a refund. Wiring it:

1. Implement `request_refund!(db, payment_intent_id:, reason:, clock:) -> refund id`. It
   runs inside the reject's transaction and only starts the refund (creates it and
   reserves `amount_refunded`). The acquirer call happens in the refund's own later
   phases.
2. In the refund phase that posts `Ledger::Flows.refund`, call
   `Balances::Holds.release_after_refund!(db, flow_id: payment_intent_id, clock:)` in the
   same transaction. It is idempotent and does nothing for a payment with no rejected hold,
   so every refund can call it.
3. Point `DEFAULT_REFUNDS` at the implementation.

`spec/support/balances.rb` (`StandInRefunds`) does exactly this, which is what the specs run.
