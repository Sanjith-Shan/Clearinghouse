# The availability sweep deadlocked with review approvals on account_balances

**What broke.** `Balances::Availability.release_due!` posts one ledger transaction per
claimed row, all in one database transaction per batch. `Ledger.post!` locks a posting's
`account_balances` rows in ascending account id, but only within that posting. A batch that
released one payment to available (pending -> available) and then another to held
(pending -> held) took `available` before `held`. An approval of a third payment of the same
merchant (held -> available) takes the two in id order, and when `held` has the lower id
(the merchant's first money went to review) that is `held` first. Each transaction then held
the row the other wanted, and Postgres aborted one with `deadlock detected`.

Looking for the same pattern everywhere a transaction posts more than once, or locks a
balance and then posts, found three more:

- **The refund of a rejected review** posted the refund (available, refund_clearing), then
  released the hold (held, available). Against an approval of another payment it was the
  same cycle as the sweep. Worse, the release locks the payment's availability row, so a
  refund that had already posted held `available` while waiting for that row, and a sweep
  that had claimed the row wanted `available` for another payment of its batch.
- **Payout `reserve!`** locked `available` with `balance_for_update`, then posted to
  `payout_clearing`. A cancel or failure of the merchant's earlier payout posts to the same
  two in id order, and `payout_clearing` has the lower id whenever another merchant paid out
  before this merchant had an available balance.
- **Settlement ingestion** posts once per line in one transaction. A run that had booked a
  dispute line (dispute_clearing) and then wanted refund_clearing could close a three-way
  cycle with a refund and a dispute win of one merchant, given the right account ids. I
  found this one by reading the code, not by seeing it fail.

**Caught by.** `spec/balances/holds_spec.rb`, "ends with every approved payment in available
exactly once and nothing left held" (a sweep with batch size 2 racing four approvers over 16
reviewed payments) was flaky: about one run in six alone, and once in a full CI run. On the
old sweep I then ran it 36 times alone: 14 failed, and the 5 failures whose error I captured
were all `PG::TRDeadlockDetected` on `account_balances`. To make it deterministic, "does not
deadlock with an approval when one batch releases to both available and held" pauses the
sweep inside `Holds.withholds?` for the second payment of the batch, runs the approval until
`pg_stat_activity` shows it waiting on a lock, then lets the sweep go on
(`spec/support/lock_order.rb`). It failed with `deadlock detected` on every run before the
fix. The refund and payout instances each have a spec built the same way that also failed on
every run before the fix. The ingestion spec checks that the run holds every settlement
balance before its first posting; it failed with the old code (nothing was locked yet).

**Fix.** `Ledger.lock_balances!(db, accounts)` locks a set of balance rows in ascending
account id in one query, creating missing accounts first. The sweep now decides every
release of its batch, locks all their accounts, then posts. The refund calls
`Holds.release_after_refund!` before its own posting, passing its entries so the release
locks held, available and refund_clearing together. `reserve!` locks available and
payout_clearing together before reading the balance. Ingestion locks every existing
settlement account before its first line. The rule and the alternatives I did not take are
in `docs/design/ledger.md`, "One lock order per database transaction". Fix commit: FIXCOMMIT
(branch `pr/deadlock-holds-sweep`). After it, the racing spec passed 20 of 20 runs.
