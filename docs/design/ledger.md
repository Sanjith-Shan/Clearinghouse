# The ledger

Code: `lib/clearinghouse/ledger/`, schema: `db/migrations/20260923120000_ledger.rb`.
The contract other areas build against is in `docs/design/interfaces.md`.

The ledger is the part of Clearinghouse that has to be right. Every movement of money is a
ledger transaction: a set of entries, each a debit or a credit of a positive amount to one
account, whose debits equal its credits in every currency. History is never edited. A
mistake is corrected by a reversal, which is a new transaction.

The design borrows two ideas from Ilya Ganelin's *Ledger: Stripe's system for tracking and
validating money movement* (2024): an immutable log of entries as the source of truth, and
clearing accounts that must return to zero when a flow finishes, so that "is the money where
it should be" becomes a query rather than an investigation.

## Accounts

An account is a code plus a currency. The code alone decides the account's kind and normal
side, so accounts are created on first use and two callers can never disagree about what
`platform:cash` is.

| code | kind | normal side | what it means |
|---|---|---|---|
| `platform:cash` | asset | debit | money in our bank account |
| `platform:processor_receivable` | clearing | debit | captured, not yet paid to us by the acquirer |
| `platform:refund_clearing` | clearing | credit | refunded, not yet taken back by the acquirer |
| `platform:dispute_clearing` | clearing | credit | disputed amount between merchant, us and the acquirer |
| `platform:payout_clearing` | clearing | credit | sent to the merchant's bank, not yet confirmed |
| `platform:fee_revenue` | revenue | credit | our processing fee |
| `platform:dispute_fee_revenue` | revenue | credit | our dispute fee |
| `platform:processing_expense` | expense | debit | the acquirer's fee to us |
| `platform:dispute_losses` | expense | debit | disputes we absorb (unused until a merchant defaults) |
| `merchant:<id>:pending` | liability | credit | owed to the merchant, not yet available |
| `merchant:<id>:available` | liability | credit | owed to the merchant, can be paid out |
| `merchant:<id>:held` | liability | credit | owed to the merchant, held (risk review, M6) |

`account_balances.balance` is signed on the account's normal side. A merchant's available
balance is positive when we owe them money and negative when they owe us.

## The money flows

Every event below is a method on `Ledger::Flows` that returns the entries, so this table and
the code cannot drift apart without a test noticing (`spec/ledger/flows_spec.rb`,
`spec/ledger/clearing_spec.rb`). The example is a $100.00 card payment with our fee of 2.9% +
30 cents ($3.20) and the acquirer's fee of 1.5% + 10 cents ($1.60).

| Flow | Event | Debit | Credit | Clearing account after |
|---|---|---|---|---|
| payment `pi_` | Capture | processor_receivable 100.00 | merchant pending 96.80, fee_revenue 3.20 | processor_receivable 100.00 |
| payment | Settlement received | cash 98.40, processing_expense 1.60 | processor_receivable 100.00 | processor_receivable 0 |
| payment | Funds become available | merchant pending 96.80 | merchant available 96.80 | (none touched) |
| payment | Funds become available, payment under review (M6) | merchant pending 96.80 | merchant held 96.80 | (none touched) |
| payment | Review opened after funds were available | merchant available 96.80 | merchant held 96.80 | (none touched) |
| payment | Review closed (approved, or its refund posted) | merchant held 96.80 | merchant available 96.80 | (none touched) |
| refund `re_` | Refund $40.00 | merchant available 40.00 | refund_clearing 40.00 | refund_clearing 40.00 |
| refund | Refund settled | refund_clearing 40.00 | cash 40.00 | refund_clearing 0 |
| dispute `dp_` | Dispute opened, fee $15.00 | merchant available 100.00, merchant available 15.00 | dispute_clearing 100.00, dispute_fee_revenue 15.00 | dispute_clearing 100.00 |
| dispute | Acquirer debits us (`dispute` line) | dispute_clearing 100.00 | cash 100.00 | dispute_clearing 0 |
| dispute | Dispute won | dispute_clearing 100.00 | merchant available 100.00 | dispute_clearing -100.00 |
| dispute | Acquirer returns funds (`dispute_reversal` line) | cash 100.00 | dispute_clearing 100.00 | dispute_clearing 0 |
| payout `po_` | Payout $50.00 | merchant available 50.00 | payout_clearing 50.00 | payout_clearing 50.00 |
| payout | Payout paid | payout_clearing 50.00 | cash 50.00 | payout_clearing 0 |
| payout | Payout failed | payout_clearing 50.00 | merchant available 50.00 | payout_clearing 0 |

Notes on the rows that differ from the first draft in the spec:

- **Settlement nets out the acquirer's fee.** The settlement file reports gross and fee, and
  the acquirer pays gross minus fee. The receivable clears for the full gross, and the fee is
  our expense. Booking cash at the gross would leave $1.60 of phantom cash, and booking the
  receivable at the net would leave $1.60 in clearing forever.
- **Disputes clear against cash, both ways.** A lost dispute is: opened, then the acquirer
  debits the amount. Nothing else happens, and dispute_clearing is back at zero. A won dispute
  adds two steps: the merchant is credited back, and the acquirer returns the money.
  Between those two, dispute_clearing is -100.00 (the acquirer owes us), which is correct and
  shows up as an open flow until the money arrives. The same entries also work for an
  acquirer that only debits when a dispute is lost: opened then won nets to zero without any
  cash moving.
- A lost dispute costs the platform nothing as long as the merchant can cover it, because the
  merchant's balance was already debited at open. `platform:dispute_losses` is for the day a
  merchant with a negative balance never recovers and we write it off. Nothing posts to it
  yet.

## Policy decisions

**Our fee is not returned on a refund.** The refund debits the merchant for the refunded amount
only. The work the fee paid for (authorization, capture, fraud checks, the acquirer's fee
on the capture) already happened, and a refund does not undo it.
Returning the fee would also make a capture-then-refund loop a way to use the platform for
free. Stripe made the same call. If it changed, the refund would add a debit to
`platform:fee_revenue` and a matching credit to the merchant, pro rata for partial refunds.

**The dispute fee is kept even when the dispute is won.** The fee pays for handling the
dispute (evidence submission, the acquirer's chargeback fee to us), and that cost is the same
whatever the outcome. Some processors return it on a win. Doing that here is one more pair of
entries on the won transaction: debit `dispute_fee_revenue`, credit merchant available.

**Negative balances after disputes (and refunds).** A dispute or refund debits the merchant's
available balance even if that takes it below zero. We don't refuse the dispute, because the
card network has already decided it. The negative balance is carried: the merchant owes us.
The next captures pay it down on their own, because `funds_available` credits the same
account. **Payouts are blocked while the available balance is zero or negative.** The payout
code (M4) reads the balance with `Ledger.balance_for_update`, which locks the row, so a
concurrent dispute cannot slip in between the check and the payout. `docs/design/payouts.md`
has the worked example and the specs. The spec also mentions debiting a
reserve before going negative. There is no reserve in M1. `merchant:<id>:held` exists for M6's
review holds, and a rolling reserve would be the same account with a release date.

**Refunds come out of the available balance, not pending.** A refund of a payment whose funds
are still pending can take available negative for a day or two, and then the policy above
applies. The alternative (debit pending first) needs the refund to know which capture's
pending funds it may touch, which is state the ledger doesn't hold.

## What the database enforces, and why it is the backstop

Ruby validates every posting first (`Ledger::Posting#validate!`) and raises a typed error
that says exactly what is wrong, for example `UnbalancedError` with `imbalances` like
`{"usd" => 10}`. The database then checks the same rules again. Two layers for one rule is
deliberate. The Ruby layer only sees writes that go through `Ledger.post!`. The database sees
every writer, including a raw SQL session, a console, a data migration written in a hurry, or
a future bug in `posting.rb`. `spec/db/ledger_schema_spec.rb` tests the database layer with raw
SQL and no Ruby ledger code at all.

**Double entry, checked at commit.** A `CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED`
on `ledger_entries` and `ledger_transactions` fails the commit if any transaction written in it
has fewer than two entries, or debits minus credits is not zero in any currency. It is
deferred because the header row and the entries are separate INSERT statements: the header
has to exist before an entry can reference it, and the moment after the header is inserted,
the transaction has zero entries. An immediate check would reject every valid posting. At
COMMIT the transaction is complete, and that is the only moment the rule means anything. The
trigger fires from both tables so that a header with no entries (which would never fire an
entries trigger) is caught too. A session can make the check stricter with
`SET CONSTRAINTS ALL IMMEDIATE`, which fails at the header insert, but it cannot turn it off.

**Append-only, twice.** Triggers reject UPDATE, DELETE and TRUNCATE on accounts, transactions
and entries, for every role including the table owner. Separately, the app role is only
granted SELECT and INSERT on them. The tests prove each layer on its own: the owner, who has
every privilege, hits the trigger, and the app role is refused by privilege before any trigger
runs. `account_balances` is the one mutable table, and the app can UPDATE it but not DELETE
from it.

**No entries added later.** Append-only alone has a hole. A balanced pair of entries appended
to a transaction that committed last week passes the double-entry check and edits history
without an UPDATE. So each header records the database transaction that created it
(`created_xact`, set by trigger, whatever the caller sends), and an entry can only be
inserted in that same database transaction.

**Currency.** An entry's currency must equal its account's, enforced by a composite foreign key
from `ledger_entries (account_id, currency)` to `ledger_accounts (id, currency)`. The spec asks
to reject "mixed currency within one account", and with accounts keyed by code and currency
that can't happen through the API. The foreign key makes it impossible through raw SQL too.
A single transaction may still touch several currencies (a settlement batch, say), as long as
each one balances on its own.

**One flow type per flow.** All transactions of a flow share its `flow_type`, checked in Ruby
(`FlowTypeMismatchError`) and by trigger. The clearing report depends on it: one flow, one SLA.

## Reversals

`Ledger.reverse!` posts the mirror image of a transaction in the same flow, with
`reverses_transaction_id` pointing at the original. Decisions:

- **A transaction is reversed at most once.** Ruby checks first. A unique index on
  `reverses_transaction_id` settles a race between two concurrent reversals, and the loser
  gets `AlreadyReversedError` (tested with two real connections).
- **A reversal cannot be reversed.** Allowing it raises a question with no good answer: after
  T, reverse(T) and reverse(reverse(T)), is T live again, and can it be reversed a second
  time? Refusing keeps "is this transaction in effect" a question with one answer. To undo a
  mistaken reversal, post the original entries again as a new transaction with its own
  description. The trigger enforces this too.
- **The mirror is checked at commit.** The deferred trigger verifies that a reversal's entries
  net the original's to zero on every account, so a hand-written "reversal" that doesn't match
  its original is refused.

## Balances and locking

`account_balances` is updated in the posting's own database transaction, so it commits or
rolls back with the entries. Rows are updated one at a time in ascending account id. Two
postings that share accounts take their row locks in the same order, so neither can hold one
while waiting for the other's. `spec/ledger/posting_spec.rb` runs six threads posting 240
transactions with entries shuffled so they touch shared accounts in opposite orders. With the
sort removed, Postgres reported `deadlock detected` on the first run. New accounts are created
in sorted order with `ON CONFLICT DO NOTHING` for the same reason.

`Ledger.balance_for_update` locks one balance row `FOR UPDATE` for check-then-post sequences
(payouts against available balance). It creates the account if needed so there is always a
row to lock, and refuses to run outside a database transaction, where the lock would be
released immediately.

`Ledger::Checker.run` recomputes every balance from entries in one query and reports each
account whose stored balance differs, including a missing balance row. The test edits a
balance as the owner role and checks that the checker finds exactly that account, and
exactly that difference.

`Ledger::Invariants` checks the global properties that model-based tests will assert after
every step: in each currency the signed sum of all entries is zero, every transaction
balances, and balances equal entries. The property tests in `spec/ledger/properties_spec.rb`
run random balanced histories against a plain-Ruby model, random unbalanced postings (Ruby
rejects each one with the exact imbalance, then the same entries as raw SQL fail at commit),
and reversals of random transactions.

## Clearing and explainability

A flow is **explained** when every clearing account it touched nets to zero within that flow's
own transactions. `Ledger::Clearing.report(db, as_of:, slas:)` reports:

- **Open flows**: every flow with a clearing account not back at zero, with the amount stuck in
  each. `past_sla` is the subset older than their flow type's SLA (`slas` maps flow type to
  seconds, and age is `as_of` minus the flow's first transaction). A flow type with no SLA
  configured is listed in `flow_types_without_sla` rather than silently never flagged.
- **Orphan clearing balances**: clearing accounts whose stored balance is not accounted for by
  the open flows behind them. Every entry carries a flow id, so summed from entries the two
  are equal by construction. The check compares the stored `account_balances` row (the number
  payouts and dashboards read) against the flows, which catches a clearing balance that moved
  with no flow behind it. It overlaps with the checker on purpose: the checker says which
  account drifted, this says the drift is money sitting in clearing that nothing explains.
- **Explainability** per flow type and currency: the share of volume in fully explained flows.
  A flow's volume is the sum of the debits in its first transaction, the amount it set out to
  move. Flows still inside their SLA count as unexplained until they clear, so the share should
  be read alongside `past_sla`.

The test builds every row of the table above plus one leaky payment, whose settlement is
booked against $99.00 instead of the $100.00 captured. Nothing tells the report which flow is
the bad one. It comes back as the only flow past SLA, with exactly $1.00 left in
`processor_receivable`, and payment explainability drops to 20/23. Reversing the bad
settlement and booking the right one makes the report healthy again.

`Ledger.explain(db, flow_id)` returns every transaction and entry of one flow with the running
clearing state after each, and `Ledger::ExplainPrinter.render` turns it into a table for a
terminal. The clearing column shows money entering clearing and leaving it:

```
Flow pi_1 · payment · 3 transactions · EXPLAINED

┌─────┬─────────────────────┬─────────────────────────────────┬────────────┬────────────┬──────────────────────┐
│ txn │ effective (UTC)     │ transaction / account           │      debit │     credit │ processor_receivable │
├─────┼─────────────────────┼─────────────────────────────────┼────────────┼────────────┼──────────────────────┤
│ #1  │ 2026-01-01 00:00:00 │ capture                         │            │            │           100.00 USD │
│     │                     │   platform:processor_receivable │ 100.00 USD │            │                      │
│     │                     │   merchant:m1:pending           │            │  96.80 USD │                      │
│     │                     │   platform:fee_revenue          │            │   3.20 USD │                      │
├─────┼─────────────────────┼─────────────────────────────────┼────────────┼────────────┼──────────────────────┤
│ #2  │ 2026-01-03 00:00:00 │ settlement                      │            │            │             0.00 USD │
│     │                     │   platform:cash                 │  98.40 USD │            │                      │
│     │                     │   platform:processing_expense   │   1.60 USD │            │                      │
│     │                     │   platform:processor_receivable │            │ 100.00 USD │                      │
├─────┼─────────────────────┼─────────────────────────────────┼────────────┼────────────┼──────────────────────┤
│ #3  │ 2026-01-03 00:00:00 │ funds available                 │            │            │             0.00 USD │
│     │                     │   merchant:m1:pending           │  96.80 USD │            │                      │
│     │                     │   merchant:m1:available         │            │  96.80 USD │                      │
└─────┴─────────────────────┴─────────────────────────────────┴────────────┴────────────┴──────────────────────┘

Explained: every clearing account this flow touched is back at zero.
```

## Alternatives considered

- **No `account_balances`, sum entries on every read.** Simpler and can't drift, but an
  overdraft check then has nothing to lock. Two payouts could both read the same sum and both
  pass. The balance row is what makes `balance_for_update` possible, and the checker is the
  price of having it.
- **Signed amounts instead of side plus positive amount.** A single signed column makes sums
  easier, but "debit 100" and "credit -100" become the same row, and a sign bug turns into a
  valid-looking entry. Side plus `amount > 0` makes a wrong sign a constraint violation.
- **A clearing account per flow** (closer to the Stripe post) instead of shared platform
  clearing accounts tagged by flow id. Per-flow accounts make "explained" a balance lookup,
  but they multiply accounts by the number of payments and complicate the account-code
  grammar. Shared accounts plus a `GROUP BY flow_id` give the same answer with one query.
- **A statement-level trigger with transition tables** instead of a row-level constraint
  trigger. It would check each transaction once rather than once per entry, but Postgres
  only allows constraint triggers `FOR EACH ROW` and rejects `REFERENCING` on them, and only
  constraint triggers can be deferred to COMMIT. At a handful of entries per transaction the
  per-row cost doesn't matter.
