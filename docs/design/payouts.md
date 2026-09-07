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
