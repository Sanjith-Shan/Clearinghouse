# Isolation: experiment 3

Which concurrency control Clearinghouse uses for money-moving transactions, and the
measurement behind it. The harness is `sim/experiments/isolation/`, the runner is
`bin/exp-isolation`, and the results land in `results/exp3-isolation/`.

> **Status: measured on a quiet machine on 2026-09-25.** Results and the decision are below.

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

The published run, on a quiet machine: `bin/exp-isolation --threads 2,8,32 --trials 5 --ops 2000
--db clearinghouse_exp3`, commit `2860114`, Apple M3 Pro, 12 cores, 18 GB, PostgreSQL 16.15 in
Docker, Ruby 3.3.12, pool size equal to the thread count. Started 2026-09-25T19:36:16Z with
nothing else heavy running. The 1-minute load average was 2.4 at the start and rose to 9.5 by
the end, most of it the experiment's own threads and Postgres. No trial crossed the harness's
high-load flag (above 12). Five trials (seeds 1 to 5) of 2,000 operations per row. Results:
`results/exp3-isolation/20260925T193616Z-quiet/results.json` (per strategy and thread count:
`summary.ops_per_s_mean`, `ops_per_s_min`, `ops_per_s_max`, `p50_ms`, `p99_ms`,
`retries_per_100_ops`, `exhausted`, `anomalies`; per-trial load under `trials[].load_average`).

| strategy | threads | ops/s mean (min-max) | p50 ms | p99 ms | retries /100 ops | ran out of retries | trials with anomalies | over-refunds (cents) | lost updates | payout double-spends | balance drift cents |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rc_read_then_write | 2 | 1262.7 (1175.7-1297.2) | 1.64 | 2.78 | 0.0 | 0 | 5/5 | 370 (2656000) | 6269 | 2 | 2133500 |
| rc_for_update | 2 | 1087.8 (1062.8-1102.9) | 1.82 | 3.28 | 0.0 | 0 | 0/5 | 0 | 0 | 0 | 0 |
| serializable_retry | 2 | 671.2 (401.3-823.7) | 1.54 | 30.28 | 27.43 | 0 | 0/5 | 0 | 0 | 0 | 0 |
| serializable_for_update | 2 | 603.7 (547.2-656.3) | 1.66 | 48.84 | 18.67 | 16 | 0/5 | 0 | 0 | 0 | 0 |
| rc_read_then_write | 8 | 1082.1 (993.6-1129.8) | 5.81 | 30.68 | 0.0 | 0 | 5/5 | 116 (5646000) | 13565 | 37 | 5489500 |
| rc_for_update | 8 | 867.9 (669.1-955.7) | 6.11 | 33.51 | 0.0 | 0 | 0/5 | 0 | 0 | 0 | 0 |
| serializable_retry | 8 | 667.6 (644.2-699.4) | 4.61 | 64.42 | 139.28 | 3 | 0/5 | 0 | 0 | 0 | 0 |
| serializable_for_update | 8 | 661.5 (607.0-711.9) | 2.05 | 163.03 | 105.09 | 138 | 0/5 | 0 | 0 | 0 | 0 |
| rc_read_then_write | 32 | 1136.5 (1091.1-1168.8) | 12.38 | 147.05 | 0.0 | 0 | 5/5 | 59 (6366000) | 15656 | 383 | 14793500 |
| rc_for_update | 32 | 1390.4 (1323.5-1460.7) | 11.45 | 73.47 | 0.0 | 0 | 0/5 | 0 | 0 | 0 | 0 |
| serializable_retry | 32 | 253.4 (211.1-342.2) | 115.28 | 360.49 | 421.86 | 143 | 0/5 | 0 | 0 | 0 | 0 |
| serializable_for_update | 32 | 178.9 (146.3-206.4) | 66.41 | 400.86 | 445.04 | 2790 | 0/5 | 0 | 0 | 0 | 0 |

Throughput counts completed operations (applied plus correctly refused). An operation that
ran out of its 10 attempts is not completed. "Ran out of retries" is out of 10,000 operations
per row.

What the numbers say:

- **READ COMMITTED read-then-write is wrong at every thread count.** All 15 of its trials
  had anomalies: 59 to 370 over-refunds (26,560 to 63,660 dollars refunded beyond what was
  captured), 6,269 to 15,656 lost updates, up to 383 payouts of money a dispute had already
  taken, and up to 147,935 dollars of balance drift. It is also the fastest strategy at 2
  and 8 threads, which is the trap.
- **All three safe strategies had zero anomalies in all 45 trials.** On this workload
  `FOR UPDATE` alone is enough, because every check reads a row the code locks.
- **The cost of SERIALIZABLE is large, and it grows with contention.** Against
  `rc_for_update`, the shipped combination `serializable_for_update` ran at 0.55x the
  throughput at 2 threads (604 against 1,088 ops/s), 0.76x at 8 (662 against 868) and 0.13x
  at 32 (179 against 1,390). At 32 threads it retried 4.5 times per operation, its p99 was
  401 ms against 73, and **2,790 of 10,000 operations (28%) ran out of retries**. Those are
  failed requests, not anomalies. `serializable_retry` without the lock did better at 32
  threads (253 ops/s, 143 ran out) and about the same at 2 and 8.
- The two earlier runs, on a loaded machine, are kept as checks:
  `results/exp3-isolation/20260924T231715Z-load10-140/` (load 10 to 140, throughput swinging
  up to 7x within a row) and `20260925T070042Z-load12-15/` (load 12 to 15, three replays
  running beside it). They agree on every anomaly count to within noise and on
  `rc_for_update` being the fastest safe strategy at 8 and 32 threads. Their throughput is
  lower and noisier and is not quoted.

## What Clearinghouse ships, and where

What the code does, read from `lib/clearinghouse/idempotency`, `payments`, `payouts` and
`ledger`:

- **Every atomic phase of a keyed request runs SERIALIZABLE** with bounded, jittered retry
  (`Idempotency::Serializable`, from `Idempotency::Runner`). Inside, the payments code locks
  the intent it checks with `PaymentIntents.lock!` (`SELECT ... FOR UPDATE`), and payout
  reservations lock the balance rows (`Ledger.lock_balances!`, `Ledger.balance_for_update`).
  So the shipped combination is `serializable_for_update`.
- **Requests that contend on one row queue before their transaction begins.** Refunds of one
  intent pass an advisory-lock turnstile on the intent, and payouts one on the merchant's
  balance (`Idempotency::Turnstile`, `docs/design/idempotency.md`). The harness
  above has no turnstile. Its 32 threads all hit the SERIALIZABLE retry loop on one row at
  once, which is what production avoids. The turnstile was added after 16 concurrent refunds
  ran requests out of retries
  (`docs/bugs/payments-concurrent-refunds-exhausted.md`).
- **Ledger balances** are updated with relative writes (`balance = balance + delta`), with
  the rows locked in sorted order. A relative write cannot lose another write at any
  isolation level. What needs a lock is a check-then-act on a balance.
- The database's `CHECK (amount_refunded <= amount_received)` is a backstop behind all of it.

## Decision

**What ships: SERIALIZABLE phases with `FOR UPDATE` inside, plus the per-row turnstile. The
numbers say this costs a lot, and I am keeping it on purpose.**

The measurement does not flatter it. On this workload `rc_for_update` is just as correct (0
anomalies in 15 trials) and faster at every thread count: 1.8x at 2 threads, 1.3x at 8 and
7.8x at 32. It never retries, while SERIALIZABLE with the lock ran 28% of operations out of
retries at 32 threads. If this workload were the whole system, `FOR UPDATE` alone would be
the right answer, and I'd say so.

It isn't the whole system, and that's why SERIALIZABLE stays:

- Not every check is one row. A sum over rows, or a "no other pending refund exists"
  query, conflicts with an insert, and a row lock can't cover a row that doesn't exist yet.
  SERIALIZABLE protects those predicates, including ones someone adds later without
  thinking about locks. `FOR UPDATE` protects exactly the rows someone remembered to lock.
  This workload doesn't exercise that difference, so here its value is an argument, not a
  measurement.
- The retry cost comes from many transactions fighting over one row inside SERIALIZABLE. The
  turnstile is meant to remove most of that in production by making same-intent and
  same-balance requests wait their turn before their transaction starts, so that the
  SERIALIZABLE retry becomes the rare case, not the 4.5-per-operation case above. The turnstiled path is
  measured in "Measuring the turnstile" below, and that measurement changes the verdict.
- A request that runs out of retries fails as a retryable 409, not as an anomaly. Losing
  throughput is recoverable, and losing money is not.

What would change the decision: a turnstiled version of this harness that still shows
SERIALIZABLE costing more than about 2x at realistic contention, with no predicate check in
the codebase that a row lock can't cover. Then the phases would move to READ COMMITTED with
explicit locks.

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
phase whose check really spans rows. The code still ships SERIALIZABLE today. Making the switch
is the next change, and it should be made with the full `--threads 2,8,32 --trials 5` sweep behind
it, since the turnstile numbers above are from two trials each.
