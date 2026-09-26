# Isolation: experiment 3

Which concurrency control Clearinghouse uses for money-moving transactions, and the
measurement behind it. The harness is `sim/experiments/isolation/`, the runner is
`bin/exp-isolation`, and the results land in `results/exp3-isolation/`.

> **Status: the results table below is pending.** The code, the anomaly definitions and the
> deterministic spec are done. The timed runs have not been published because the machine
> was shared and heavily loaded when the harness was built (1-minute load average 40 to 65
> on 12 cores); numbers from that are not worth printing. The final run happens on a quiet
> machine, and this section gets the table and the throughput cost then.

## The workload

One merchant balance and a stream of payments, each captured for 100.00. T threads, each
holding its own connection (pool size = T), share N operations:

| operation | share | what it does |
|---|---:|---|
| refund | 70% | a 10.00 partial refund of the "hot" payment: 10 fit. It debits the payment's `amount_refunded` and the merchant's available balance |
| dispute | 10% | debits 15.00 from available. Never refused, may go negative (the network has decided) |
| payout | 10% | pays out everything available; refused at zero or below |
| credit | 10% | 50.00 of earlier captures becoming available, so payouts keep having something to pay |

All refunds go to the same payment until one is refused for lack of room, and then every
thread moves to the next payment. So most of the time T transactions are fighting over one
payment row, and all of them over the one balance row. That is the contention the spec
asks for: many partial refunds against one payment, plus a payout and a dispute against the
same balance.

Each operation is written once (`Operations` in `strategies.rb`) as read, then decide, then
write absolute values computed from what was read. The strategies differ only in the
transaction around that code:

| strategy | transaction | reads |
|---|---|---|
| `rc_read_then_write` | READ COMMITTED | plain `SELECT` |
| `rc_for_update` | READ COMMITTED | `SELECT ... FOR UPDATE` |
| `serializable_retry` | SERIALIZABLE, retried on 40001/40P01 (up to 10 attempts, full-jitter backoff 1 ms doubling to a 50 ms cap) | plain `SELECT` |
| `serializable_for_update` | the same, with `FOR UPDATE` reads | `SELECT ... FOR UPDATE` |

The fourth row is not in the spec. It is there because it is what the idempotency layer's
atomic phases actually run (a SERIALIZABLE transaction around payments code that locks the
intent), so the shipped combination gets measured too.

**No CHECK constraints.** The scratch tables have none: no `amount_refunded <=
amount_received`, nothing on the balance. The point is to measure what each isolation
strategy guarantees on its own. Production has those constraints as well
(`db/migrations/20260924100000_payment_intents.rb`), and they would turn a read-then-write
over-refund into an error. That is defence in depth, not a substitute for getting the
concurrency control right: a constraint can only reject the bad state after the fact, it
cannot stop a lost update that leaves every row individually valid.

## How anomalies are counted

From the data after each trial (`Audit` in `schema.rb`), never from what the operations
reported. Every write sets the row's `version` to the version it read plus one, and every
movement logs the balance version (and for refunds, the payment version) it read.

- **Over-refund.** A payment whose logged refunds add up to more than it captured.
- **Lost update.** Each committed write moves its row's version forward by one from what it
  read, and versions start at 0, so on each row `committed writes - final version` is how
  many writes were overwritten by another write that had not seen them. Summed over payment rows and the
  balance row.
- **Payout double-spend.** A committed payout computed from the same balance version as a
  committed dispute. Both took money out of the same snapshot of the balance, so the payout
  paid out money the dispute had also taken. (Precisely: this is the spec's "a payout that
  spent money a dispute had already taken". Going negative on its own is not an anomaly here,
  because disputes are allowed to carry the balance negative, docs/design/ledger.md.)
- **Balance drift.** `final available - (opening + every logged movement)`, in cents. Zero
  when nothing was lost. It is the dollar size of the lost updates on the balance.

Under read-then-write the version column is itself subject to the lost updates it measures:
a very stale writer can set it backwards. The count is still the number of writes whose
effect is missing from the final row, because the stale write overwrote every one of them.
The safe strategies never write a stale version, so for them the checks are exact.

## The anomalies, and the interleaving behind each

The spec (`spec/experiments/isolation_spec.rb`) forces each of these with two connections and
explicit ordering, not a race: T1 reads, T2 reads (or blocks trying to), T1 writes and
commits, then T2 continues. It waits on `pg_stat_activity` to see T2 blocked on a lock, so
it is deterministic.

**Over-refund (and a lost update on the payment).** A payment of 10.00, two full refunds:

```
T1: SELECT payment        -> refunded 0, room 10.00
T2: SELECT payment        -> refunded 0, room 10.00
T1: UPDATE payment SET amount_refunded = 10.00; COMMIT
T2: UPDATE payment SET amount_refunded = 10.00; COMMIT   (overwrites T1's write)
```

Both refunds commit; 20.00 left the merchant for a 10.00 payment. `amount_refunded` says
10.00, so the next refund check believes there is still room. Had T1 not committed yet,
T2's UPDATE would wait for T1's row lock, and then write the value it computed from its old
read anyway: the write lock serializes the writes, not the decisions.

- With `FOR UPDATE`, T2's `SELECT` blocks until T1 commits and then returns T1's row: room 0,
  T2 is refused. One attempt each.
- Under SERIALIZABLE, T2's `UPDATE` of a row changed by a transaction that committed after
  T2's snapshot fails with 40001. The retry reads the new row and is refused. Two attempts.
- SERIALIZABLE with `FOR UPDATE`: T2 blocks on the lock as in RC, but when T1 commits its
  snapshot is still older than the row, so it gets 40001 and retries anyway. The lock turns
  a race into a queue; it does not remove the retry.

**Payout of money a dispute took.** Balance 50.00, a payout and a 15.00 dispute:

```
T1 (payout):  SELECT balance -> 50.00
T2 (dispute): SELECT balance -> 50.00
T1: UPDATE balance SET available = 0; COMMIT             (paid out 50.00)
T2: UPDATE balance SET available = 35.00; COMMIT         (overwrites the 0)
```

The merchant was paid 50.00 and disputed 15.00, and the balance says 35.00 instead of
-15.00. That 35.00 will be paid out again on the next payout. With `FOR UPDATE` or
SERIALIZABLE the dispute runs after the payout and takes the balance to -15.00, which is
the carried-negative rule working as designed.

**Lost balance updates** are the general case of the above: any two operations that read
the same balance and both write. Refund against refund, credit against payout, and so on.
Balance drift is their cost in cents.

## Results

Pending the quiet-machine run (see the status note at the top). The table will come from
`bin/exp-isolation --threads 2,8,32 --trials 5 --ops 2000`, with the machine, Postgres
version, pool size and per-trial load averages in `results/exp3-isolation/results.json`.
Any trial with a 1-minute load average above 12 is flagged there.

Columns: throughput (completed operations per second, including refusals, since a refusal
is a correct answer), p50 and p99 operation latency including retries, serialization
retries per 100 operations, operations that ran out of retries, and each anomaly count.

## What Clearinghouse ships, and where

What the code on main does today, read from `lib/clearinghouse/payments` and
`lib/clearinghouse/ledger`:

- **Refunds** (`Refunds.reserve!`) run in a transaction at the default isolation, which is
  READ COMMITTED (no isolation level is passed to `db.transaction`). They take the intent
  with `PaymentIntents.lock!`, a `SELECT ... FOR UPDATE`, check the room left, insert the
  refund `pending` and add its amount to `amount_refunded`. That is `rc_for_update`.
  The database's `CHECK (amount_refunded <= amount_received)` backs it up. `record!` locks
  the refund row and the intent the same way.
- **Ledger balances** are updated with relative writes (`balance = balance + delta`), with
  the rows touched in sorted order. A relative write cannot lose another write, whatever the
  isolation level, so postings are safe without any lock; what needs a lock is a
  check-then-act on a balance, and `Ledger.balance_for_update` provides that `FOR UPDATE`
  read for payouts (docs/design/ledger.md).
- **Payouts and disputes** are not on main yet. The ledger design already says payouts must
  read the balance with `balance_for_update`, which is `rc_for_update` again.
- **The idempotency layer** (on the payments branch, not yet on main) runs each atomic phase
  in a SERIALIZABLE transaction with bounded, jittered retry, as the spec asks. Around the
  code above, that makes the shipped combination `serializable_for_update`.

- **Refunds of one payment inside the framework** also pass an advisory-lock turnstile on the
  intent before their SERIALIZABLE phases begin (`Idempotency::Turnstile`,
  `docs/design/idempotency.md`), because `serializable_for_update` still aborts every waiter
  once per winner ahead of it, and 16 concurrent refunds ran some requests out of retries.

The decision the numbers will test: row locks where the code knows which row it is
checking, SERIALIZABLE around the whole phase. `FOR UPDATE` protects exactly the rows you
remember to lock. SERIALIZABLE also protects the checks that are not a single row: a read of
a sum, a "no other pending refund exists" query, anything where the conflicting write is an
insert. It costs retries under contention, and the lock inside keeps those retries short by
making the loser wait for the winner instead of doing its work twice.

If the quiet-machine run shows `rc_for_update` anomaly-free and clearly faster on this
workload, this section will say so plainly, with the cost of SERIALIZABLE in operations
per second and retries per 100 operations, and state whether that cost is worth the
protection for predicates this workload does not exercise.

## Measuring the turnstile

The case for shipping SERIALIZABLE rested on two things this experiment had not measured:
(a) production puts `Idempotency::Turnstile` (a session advisory lock taken before `BEGIN`) in
front of hot-object phases, which should turn serialization conflicts into orderly waiting;
(b) SERIALIZABLE protects checks that span several rows, which a row lock cannot cover.

**The strategies.** Two more rows in `strategies.rb`, both `Turnstiled`, which call the real
`Clearinghouse::Idempotency::Turnstile.through` (not a copy) around another strategy:

| strategy | what it is |
|---|---|
| `serializable_turnstile` | advisory lock, then `serializable_for_update` with its retry loop inside the lock, as `Idempotency::Runner#commit` wraps `commit_serializable` |
| `rc_for_update_turnstile` | advisory lock, then `rc_for_update` |

Queue names follow production: a refund queues on `payment_intent:<id>`
(`Payments::Flows.intent_queue`), a payout on the balance (`Payouts::Flows`). Disputes and
credits (funds becoming available) have no `queue_on` in production, since they run outside
the idempotency framework, so here they take no turnstile either. One difference from
production: the retry loop is the harness's (10 attempts, 1 ms doubling to 50 ms), not
`Serializable::Policy` (8 attempts, 5 ms doubling to 250 ms), so that the only thing that
differs from `serializable_for_update` is the turnstile.

The spec forces the turnstile's interleaving too: T1 holds the lock mid-refund, T2 is seen
waiting on it in `pg_stat_activity`, T1 commits, and T2 starts its transaction after that, is
refused with no retry (`[:declined, 1]`, against `[:declined, 2]` without the turnstile).

**The run.** `results/exp3-isolation/20260925-125032-turnstile/`, all six strategies in one
run. This was a short sweep under a deadline, `--threads 8,32 --trials 2 --ops 1000`, not the
full `2,8,32 x 5 x 2000`: treat the throughput as indicative, two trials per row. Machine quiet:
1-minute load average 3.14 before and 4.01 after, on 12 cores; no trial flagged high load.

| strategy | threads | ops/s mean (min-max) | p50 ms | p99 ms | retries /100 ops | exhausted | anomalies |
|---|---:|---:|---:|---:|---:|---:|---:|
| rc_read_then_write | 8 | 1303.7 (1273.8-1333.5) | 4.8 | 22.87 | 0.0 | 0 | 2/2 trials |
| rc_for_update | 8 | 1258.9 (1228.1-1289.7) | 4.13 | 18.86 | 0.0 | 0 | 0 |
| serializable_retry | 8 | 652.3 (643.3-661.3) | 5.01 | 64.32 | 138.75 | 0 | 0 |
| serializable_for_update | 8 | 716.3 (708.4-724.3) | 1.9 | 158.29 | 102.35 | 28 | 0 |
| serializable_turnstile | 8 | 634.4 (619.1-649.6) | 5.96 | 108.71 | 60.05 | 1 | 0 |
| rc_for_update_turnstile | 8 | 974.7 (927.9-1021.5) | 7.82 | 21.85 | 0.0 | 0 | 0 |
| rc_read_then_write | 32 | 1074.4 (1016.6-1132.1) | 14.05 | 141.86 | 0.0 | 0 | 2/2 trials |
| rc_for_update | 32 | 1240.0 (1227.0-1252.9) | 14.18 | 84.96 | 0.0 | 0 | 0 |
| serializable_retry | 32 | 296.4 (254.6-338.1) | 94.83 | 337.29 | 400.3 | 34 | 0 |
| serializable_for_update | 32 | 288.6 (274.7-302.5) | 36.67 | 276.31 | 401.65 | 425 | 0 |
| serializable_turnstile | 32 | 633.8 (630.1-637.4) | 13.51 | 503.7 | 86.9 | 3 | 0 |
| rc_for_update_turnstile | 32 | 1161.3 (1070.0-1252.5) | 22.19 | 91.25 | 0.0 | 0 | 0 |

What it shows:

- **The turnstile does what it was built for at high contention.** At 32 threads it takes the
  shipped combination from 288.6 to 633.8 ops/s, and from 425 operations out of retries (21%
  of 2,000) to 3. At 8 threads it does not help throughput (634.4 against 716.3): the queue
  costs a round trip per operation and there was little retry storm to remove.
- **It does not remove the retries.** 60 and 87 retries per 100 operations remain. A refund
  queues on the payment but also writes the balance, and disputes and credits write the
  balance with no queue at all, so SERIALIZABLE still aborts on the balance row. Queuing every
  balance writer on the balance would make it a per-merchant mutex; production does not do that.
- **It is still about 2x slower than `rc_for_update`.** 1258.9 / 634.4 = 1.98x at 8 threads,
  1240.0 / 633.8 = 1.96x at 32, with a p99 of 504 ms against 85 ms at 32. The turnstile in front
  of READ COMMITTED buys nothing either: `rc_for_update_turnstile` is slower than plain
  `rc_for_update` (974.7 against 1258.9 at 8 threads), because the row lock already queues.

**Argument (b): is there a multi-row check in the real code?** I read the check-then-act paths
in `lib/clearinghouse/payments`, `balances`, `payouts`, `disputes`, `reconciliation` and
`ledger`. I did not find a money check that spans rows and is not already serialized by a row
lock:

- Refund room is `amount_received - amount_refunded` on the intent row, read `FOR UPDATE`
  (`PaymentIntents.lock!`). One row.
- Payout funds are the materialized `account_balances` row, read `FOR UPDATE`
  (`Ledger.balance_for_update`). Ledger postings are relative writes. One row.
- "An automatic payout already exists for this merchant, currency and day"
  (`Payouts.reserve!`) is a predicate over `payouts`, but it is read after `lock_balances!` has
  locked the merchant's balance rows, so a second reserve waits for the first to commit and,
  under READ COMMITTED, its next statement sees the first's insert. The row lock covers it.
- The closest thing to a real predicate check is `check_flow_type!` in `ledger/posting.rb`: "no
  ledger transaction for this flow_id has a different flow_type", read without a lock before
  the insert. Two concurrent first postings of one flow_id with different types could both pass
  under READ COMMITTED. That is a bookkeeping-consistency check, not a money check, and flow ids
  are minted by one flow each, so it would take a bug elsewhere to reach it. I did not write a
  spec for it in the time available.

So argument (b) is future-proofing today: SERIALIZABLE would protect a sum-over-rows or
"no other pending X" check if one is added, but none guards money now.

**Verdict.** With the turnstile, SERIALIZABLE is no longer a retry storm at 32 threads, but it
is still about 2x slower than `rc_for_update` at both contention levels measured, still retries
60 to 87 times per 100 operations, and the multi-row protection it pays for guards no money
check in the current code. By the rule this section set out, the decision should flip to READ
COMMITTED with `FOR UPDATE` on the rows each check reads, with SERIALIZABLE kept for any future
phase whose check really spans rows. I have not made that change; it is the coordinator's call.
