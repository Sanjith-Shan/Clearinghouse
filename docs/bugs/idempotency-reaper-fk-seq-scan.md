# The idempotency reaper seq-scanned payment_intents once per deleted key

**What broke.** `payment_intents.locked_by` references `idempotency_keys (id)` with
`ON DELETE SET NULL` (migration `20260924110000_idempotency_keys.rb`), but nothing indexed
`locked_by`. Every key `Idempotency::Reaper.run` deletes fires the constraint's trigger,
which runs `UPDATE payment_intents SET locked_by = NULL WHERE locked_by = $1`, and with no
index that is a sequential scan of `payment_intents`. One reap cost keys deleted x payment
intents: quadratic in traffic, with no error, only a delete that got slower every day.

**Caught by.** Profiling during the experiment 8 replay, not by a test. Sampling
`pg_stat_activity` found the reaper's `DELETE FROM idempotency_keys` active in 89 of 150
samples. `EXPLAIN ANALYZE` of that delete on the replay database (about 22k payment intents,
5,594 keys to reap) showed `Trigger for constraint payment_intents_locked_by_fkey:
time=49648 ms`, 49.7 s in total. With
`CREATE INDEX payment_intents_locked_by ON payment_intents (locked_by) WHERE locked_by IS NOT NULL`
the same reap took 230 ms. These are one measurement each on a busy machine, not a benchmark.

**Fix.** Migration `20260927100000_payment_intents_locked_by_index.rb` adds that index. It
is partial because almost every intent is unlocked, and the trigger's lookup is an equality
on a non-null id, which implies `locked_by IS NOT NULL`, so even the generic plan can use it.

Two specs in `spec/db/foreign_key_indexes_spec.rb` keep this class of bug out:

- "has an index leading with the columns of every foreign key" reads every foreign key in
  the schema from `pg_constraint` and fails for any whose columns do not lead a valid
  index (total, or partial on `<column> IS NOT NULL`). On main it failed on
  `payment_intents (locked_by) -> idempotency_keys: payment_intents_locked_by_fkey`.
- "plans the reaper cascade into payment_intents as an index lookup" takes the generic plan
  of the trigger's `UPDATE ... WHERE $1 = locked_by` with seq scans priced out and checks it
  is an index scan on `payment_intents_locked_by`. It asserts the plan, not a time.

Fix commit: bef0d47 (branch `pr/fkindex-locked-by`).
