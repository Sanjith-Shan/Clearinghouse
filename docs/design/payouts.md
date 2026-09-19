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

- **Scheduling is part of the capture.** `Payments::Support.post_capture!` posts the
  capture and then calls `Payments::Seams.schedule_availability`, which calls
  `Availability.schedule!(db, flow_id:, merchant_id:, net:, available_on:, clock:)`, in the
  same transaction. The capture and its
  schedule commit together or not at all, so there is never pending money with no release
  scheduled, or a release for a capture that rolled back. `schedule!` is idempotent on
  `flow_id` (same terms return the existing row, different terms raise `ConflictError`),
  because a capture phase retried after a crash may call it again.
- **`available_on` is the start of a UTC day**, `Availability.available_on(captured_at:,
  delay_days:)` (or `available_on_for`, which reads the delay from the merchant). Stripe's `available_on` is a date, and a merchant reading
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

`payout.created`, `payout.paid`, `payout.failed` and `payout.canceled` (and `review.opened`
and `review.closed` below) are emitted in the same transaction as the change they report,
through `Balances::EventSink`. The default, `OutboxEventSink`, calls `Events.emit!`, so each
event exists if and only if its change committed. Domain specs pass a recording sink that
also checks every event is emitted inside a transaction. These events carry no request id
yet, because the sink interface doesn't pass one. Threading the request's
`Events::Request` through is the next step if webhook consumers need it.

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

### How a reject refunds

`POST /v1/reviews/:id/reject` is an idempotent flow, `review.reject`
(`Balances::ReviewFlows::Reject`), run by the idempotency framework like `POST /v1/refunds`:

```
started -> refund_created -> refund_requested -> refund_recorded -> finished
```

1. `started -> refund_created`, one transaction: `close_hold!` with
   `Balances::PaymentsRefundRequester`, whose `request_refund!` runs the refund's first step,
   `Payments::Refunds.reserve!` (a full refund, reason `fraudulent`, created pending, with its
   amount reserved on the intent). The refund id goes into the key's `flow_state`. If the
   payment can't be refunded (already refunded, not captured), the payments error comes back,
   the transaction rolls back, the review stays open, and the 400 is the stored answer.
2. `refund_created -> refund_requested -> refund_recorded` are the refund flow's own phases
   (`Payments::Flows::Base#refund_phases`, shared with `refund.create`): commit the promise,
   call the acquirer under the refund's id, record the answer. A resumed phase asks the
   acquirer about that id before sending anything.
3. `Refunds.mark_succeeded` posts `Flows.refund` and calls `Holds.release_after_refund!` in the
   same transaction. That call is a no-op for a payment without a rejected review, so every
   refund makes it.

`spec/api/reviews_spec.rb` runs this end to end: a real card payment, a hold, the sweep,
then a reject. The acquirer gets exactly one refund, the refund succeeds, held goes to
zero, and available ends at -$3.20 (the fee is not returned). If the acquirer gives no
definite answer, the reject answers a retryable 503 with the review already closed as
rejected and the refund pending, and the money still held. The key stays at
`refund_requested`, and the client's retry or the completer finishes it: it asks the
acquirer, records the refund once, and releases the held money. The same spec crashes the
reject at every one of its recovery points (from the registry, before and after commit)
and checks the completer and a retry end with one refund and the right balances.

Before the idempotency framework landed, the route ran the reserve in one transaction and
then called the acquirer inline, outside any key. A lost answer left the refund pending
with nothing that would ever finish it, and a retry of the reject got `review_closed`.

Callers without a request context get `UnwiredRefundRequester` by default, which raises
rather than closing a review without a refund. The domain specs use `StandInRefunds`
(`spec/support/balances.rb`) because they post captures at the ledger level with no
payment_intents row to refund.

## Negative balances

The policy was set in `docs/design/ledger.md`. This is how it plays out with payouts. Specs
are in `spec/payouts/negative_balance_spec.rb`, which posts disputes and refunds at the ledger
level through `Ledger::Flows`, the way the disputes and payments areas will.

**A dispute or refund may take available below zero.** The card network has already
decided a dispute, and a refund the merchant asked for is owed to the cardholder. Refusing
either because the merchant's balance is low would only move the loss to us. The debit is
posted in full, and the negative balance is a debt the merchant owes the platform.

**Payouts are blocked while available is zero or negative.** `reserve!` checks
`available.positive?` under the balance row lock, and otherwise raises
`BalanceInsufficientError` (API: `balance_insufficient`). The automatic sweep only looks at
positive balances, and re-checks under the lock.

**Later captures pay the debt down on their own.** Availability credits the same
`merchant available` account, so each release reduces the debt before anything becomes
payable. Nothing tracks the debt separately, because the balance *is* the debt.

**Held money does not pay it down.** Money under review stays in `held` until the review is
approved, like any other money. Approval moves it to available, and at that point it
covers the debt first.

Worked example, from the first spec (fee 2.9% + 30c, dispute fee $15.00):

| Step | Entries | Available after | Payout? |
|---|---|---|---|
| $100 captured and released | Dr pending 96.80 / Cr available 96.80 | 96.80 | yes |
| Payout of everything | Dr available 96.80 / Cr payout_clearing 96.80 | 0.00 | blocked at zero |
| Dispute $100 opened | Dr available 100.00, Dr available 15.00 / Cr dispute_clearing 100.00, Cr dispute_fee_revenue 15.00 | -115.00 | blocked |
| $100 captured and released | Dr pending 96.80 / Cr available 96.80 | -18.20 | blocked |
| $50 captured and released | Dr pending 48.25 / Cr available 48.25 | 30.05 | yes, 30.05 and no more |

A refund past the balance works the same way (Dr available / Cr refund_clearing), and so
does a review opened after its money was paid out (Dr available / Cr held).

**Racing a dispute.** The dispute's posting updates the same `account_balances` row that
`reserve!` locks, so a payout and a dispute on one merchant serialize. Either the payout
goes first and the dispute then takes the balance negative, or the dispute goes first and
the payout sees only what is left. A spec runs the two at once and checks that the result
is one of those two outcomes. It can't tell "decided on a stale balance" apart from "went
first", so the proof that the lock matters is the 12-thread payout spec above.

**What is not built.** The spec mentions debiting a reserve before going negative. There is
no rolling reserve. It would be a fourth merchant account that a share of each capture is
released into, with its own `available_on`, and the availability sweep already has the
shape for it. Nothing writes off a debt that is never repaid either (`platform:dispute_losses`
exists for that). Both are policy decisions for a real platform, and nothing in M4 or M6
depends on them.

## Running it

`spec/api/payment_to_payout_spec.rb` runs the whole path through the real payments API:
confirm, the scheduled release, `GET /v1/balance` before and after, a payout, the bank's
notification, and the payout's flow explained with its events in the outbox.

Everything here is driven by the clock, and the order matters:

1. `Availability.release_due!`: due money to available, or to held under review.
2. `Payouts.run_scheduled!`: today's automatic payouts, which see what step 1 released.
3. `Payouts.resume_incomplete!`: payouts whose request stopped mid-way.
4. The notification poller (disputes area) calls `Payouts.handle_notification` for each
   `payout.paid` and `payout.failed`.

Each step is idempotent, so re-running it after a crash is safe. Steps 1 and 2 also have
specs that run several copies at once. Steps 3 and 4 rely on the payout row lock and the
recovery point checks for that. Something has to call them on a schedule. That is the worker the
coordinator wires up (or `bin/demo`), not this area.
