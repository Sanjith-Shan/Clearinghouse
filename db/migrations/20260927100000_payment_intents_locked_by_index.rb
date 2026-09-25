# typed: false
# frozen_string_literal: true

# An index for the foreign key payment_intents.locked_by -> idempotency_keys (id).
#
# The key is ON DELETE SET NULL, so every idempotency key the reaper deletes makes
# Postgres look for payment intents still locked by it. Without an index on
# locked_by that lookup is a sequential scan of payment_intents, once per deleted
# key: a reap costs keys x intents. In the experiment 8 replay (22k intents) one
# reap of 5,594 keys spent 49.6 s in the constraint's trigger; with this index it
# took 230 ms (docs/bugs/idempotency-reaper-fk-seq-scan.md).
#
# Partial, because almost every intent is unlocked, and the lookup is an equality
# on a non-null id, so it can always use it.
Sequel.migration do
  up do
    run 'CREATE INDEX payment_intents_locked_by ON payment_intents (locked_by) WHERE locked_by IS NOT NULL'
  end

  down do
    run 'DROP INDEX payment_intents_locked_by'
  end
end
