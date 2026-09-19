# The scheduler

Code: `lib/clearinghouse/scheduler.rb`, `bin/scheduler`. Spec: `spec/integration/scheduler_spec.rb`.

Several parts of Clearinghouse only move when time passes: authorizations lapse, captured
money becomes available, automatic payouts go out, and requests that stopped half way have to
be finished by someone. Each part is a sweep that is idempotent and safe to run concurrently
with a copy of itself. The scheduler is the one process that runs them on a clock, in the
order they depend on.

## One tick

| # | Step | Calls | Why here |
|---|---|---|---|
| 1 | expiry | `Payments::Expiry.sweep!` | independent of the rest |
| 2 | notifications | `Acquirer::NotificationPoller#poll` with `Settlement.notification_handlers` | before money moves: a dispute opened overnight takes its money out of available before today's payout is sized. It also applies `payout.paid` and `payout.failed` |
| 3 | settlement | `Reconciliation::Ingestor#ingest` for today's file (and any day skipped since the last file, up to 7), then `#match_pending` | after the poller, so lines for disputes it just recorded find their flow |
| 4 | missing lines | `Reconciliation::MissingDetector#run` | after 3, since "missing" is measured in files ingested |
| 5 | (extra steps) | whatever a deployment passes as `extra_steps:` | before money moves |
| 6 | availability | `Balances::Availability.release_due!` | before payouts, so today's newly available money is paid today |
| 7 | payouts | `Payouts.run_scheduled!` | after 2 and 6 (`payouts.md`, "Automatic payouts") |
| 8 | payout resume | `Payouts.resume_incomplete!` | finishes automatic payouts, which have no idempotency key |
| 9 | completer | `Idempotency::Completer#run_once` via `Api::Completion` | finishes API requests, payouts and review decisions included |
| 10 | reaper | `Idempotency::Reaper.run` | last; it only deletes finished keys |

Steps 2 to 4 follow the order experiment 5 runs them in (`reconciliation.md`). A payout made
in step 7 is paid a simulated day later, so its `payout.paid` is applied by step 2 of a later
tick.

`Scheduler#tick!(clock)` runs one pass and returns a `TickReport`: each step's summary and the
error of each step that failed. A step that raises does not stop the others. A bank outage
fails steps 3 and 4 and must not stop authorizations from expiring or the completer from
finishing requests that don't need the bank. The failure is in the report, and the next tick
tries again, which is safe because every step is idempotent.

`tick!` takes the clock explicitly so specs can drive a day in a few calls on a
`Clock::Test`. Steps that read time from the dependencies (expiry, the completer) get a copy
of the dependencies with that clock, so every step of a tick sees the same now. Without an
argument it uses the dependencies' own clock, which is the real one in `bin/scheduler`.

## The process

`bin/scheduler [--once] [--interval SECONDS] [--grace SECONDS] [--limit N]` builds its
dependencies with `Dependencies.from_env`, like the server, ticks every `--interval` seconds
of real time (default 5), and prints one JSON line per tick. SIGINT or SIGTERM lets the
current tick finish. Running two schedulers is safe but pointless: the sweeps claim rows with
`SKIP LOCKED` or unique indexes, and the completer's leases keep two from resuming one key.

`bin/completer` still exists and runs steps 1, 9 and 10 only, and `bin/poller` step 2 only. The scheduler supersedes it for a
deployment; the completer stays for experiments that want only request recovery.

## The acquirer side

The poller keeps its cursor in `acquirer_cursors` under the name `acquirer`, the same as
`bin/poller`, and a notification's effects, its processed row and the cursor commit together,
so running both is safe. A handler that raises stops the poller at that notification (nothing
is skipped), shows up as the `notifications` step's error, and is retried next tick.
Settlement ingestion asks for a date at most once after it has a file for it: ingesting a
date twice is a no-op anyway, and the file is frozen at the acquirer once generated. Making
the dispute and notification handlers idempotency flows of their own is a separate piece of
work. They already are idempotent through the poller's processed-notification row.

## Not built

A real deployment would run steps 2 and 3 once a day at a fixed hour rather than every tick.
Running them every tick is correct (each is a no-op once the day's work is done) and costs one
indexed query each. There is no leader election. None is needed for correctness, for the
reasons above.
