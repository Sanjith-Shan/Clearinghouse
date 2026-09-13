# The dispatcher cursor stalled on a transaction in another database

**What broke.** The webhook dispatcher only moves its cursor past an events `seq` once every
transaction that could still commit a lower one has ended. The first version decided that
by recording `pg_snapshot_xmax(pg_current_snapshot())` with the barrier and waiting until
`pg_snapshot_xmin` of a later snapshot reached it. Transaction ids and snapshots are
cluster-wide in Postgres, so any open transaction in any database on the server held the
cursor back. Deliveries still went out (fan-out never waits for the cursor), but each pass
rescanned everything above the stuck cursor, which grows without bound.

**Caught by.** `spec/webhooks/dispatcher_spec.rb`. While I was working on the next branch,
four dispatcher examples failed with `cursor stuck at 0`. `pg_stat_activity` showed a
`DROP DATABASE` for another agent's test database that had been waiting, with a transaction
id, for eight minutes. The same thing in production would be any long transaction anywhere
on the cluster: a migration, a report, an idle-in-transaction session.

**Fix.** The barrier now records the virtual transaction ids holding a `RowExclusiveLock`
on `events` in this database (from `pg_locks`), and passes once none of them holds its
`virtualxid` lock, meaning none is still running. An `INSERT` takes the table lock when it
opens the table, before its `seq` default is evaluated, so every transaction that could
commit a lower seq is on the list, and nothing else is. A regression example holds a
transaction with an xid open in the `postgres` database and checks that the cursor still
moves; I ran it against the old code, where it fails with `cursor stuck at 0, wanted 1`.
Fix commit ac91458 (branch `pr/webhooks-delivery`).
