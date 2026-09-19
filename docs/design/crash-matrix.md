# Experiment 2: crash at every recovery point

Code: `bin/crash-matrix`, `sim/experiments/crash_matrix/`. Specs:
`spec/experiments/crash_matrix_plan_spec.rb` (the plan is the registry) and
`spec/experiments/crash_matrix_run_spec.rb` (three cases end to end against real processes,
one of them in completer mode).
Results: `results/exp2-crash-matrix/`.

`idempotency.md` argues that a request can stop at any recovery point and be finished later
without losing, doubling or changing anything. This experiment checks the argument point by
point. It kills a real server process at each point, restarts it, recovers the request, and
checks the outcome against a request that was never interrupted. The approach is Brandur
Leach's atomic phases and recovery points (reading list 1). What I added is testing every
point mechanically.

## What a case is

The cases are `Payments::Flows.registry.crash_points`, and nothing else. Each recovery point of
each registered flow has two crash moments:

- `<flow>:<point>`: `Process.exit!(86)` right after the phase that reaches `point` commits.
- `<flow>:<point>:before_commit`: the same, inside that phase's transaction, so Postgres rolls
  the phase back when the connection dies.

Nobody wrote the list down, so nobody can forget to add a point. `CrashMatrix.plan` maps each
crash point to a case, so a flow such as payouts is in the matrix the moment it is registered,
with no change to the harness. A crash test still has to know how to set up the flow's
preconditions, so a flow with no scenario is planned like any other, but each of its cases fails
with `MissingScenarioError` and counts against the headline. The report lists such flows. They
fail loudly instead of disappearing from the matrix.

The plan spec checks that the plan equals `registry.crash_points` exactly, in order. It also
checks that adding a phase to a toy flow adds its two cases with no change to the harness, that
an unknown flow's cases are planned and then fail, and that every case name fires the real
`CrashHook::Armed`. On this branch the registry has 5 flows and 24
recovery points, so the matrix has 48 cases. The headline in the report is computed from the
run, never typed in.

On top of the registry there is one variant (see below): `confirm:authorization_requested`
with the acquirer dropping its answers. The headline doesn't count variants.

## One case, step by step

Three processes last for the whole run: `bin/sim`, `bin/fake-riskgate`, and a recording proxy
that sits in the harness between the API and the simulator. Each case resets them:
`/admin/reset` on the simulator, and one `TRUNCATE` of every table, done as the owner with
triggers off for that transaction (the ledger's append-only triggers refuse it otherwise).
`spec/support/db.rb` cleans the same way. The API is a new Puma process every time it starts.

1. **Fresh world.** Empty database, empty simulator, one merchant written directly.
2. **Armed server.** Start the API with `CLEARINGHOUSE_ENV=experiment`,
   `CLEARINGHOUSE_CRASH_AT=<case>` and `CLEARINGHOUSE_IDEMPOTENCY_LOCK_TIMEOUT=1`.
3. **Preconditions, through the API.** Each flow's scenario sets up what it needs: capture and
   cancel get a confirmed manual-capture intent (so cancel has an authorization to void),
   refund gets a succeeded intent, confirm gets a created one, and create gets nothing. Every
   payment uses `pm_card_visa`. A setup only ever calls *other* flows, so it can't reach the
   point it is preparing. What the API can't create is written to the database by the
   scenario's `prepare` afterwards: a review hold for `review.reject` and `review.approve`,
   and money made available (the availability sweep, run on a clock three days ahead) for
   `payout.create` and `payout.cancel`.
4. **Snapshot, send, die.** Snapshot the merchant's state, then send the request with an
   Idempotency-Key. The case passes `crashed` only if the client's connection ends with no
   response *and* the process exits with status 86. A process that exits any other way, or not
   at all, is a failure.
5. **State at the crash.** The key row must be at the case's point (after commit), at the
   previous point (before commit), or missing (`started:before_commit`, where the insert itself
   rolled back). A second snapshot is taken for the rollback comparison below.
6. **Clean server, recover.** Start the API again without `CLEARINGHOUSE_CRASH_AT` and recover
   (see "Recovery modes").
7. **Retry again.** Send the same request under the same key once more. The answer must equal
   the recovered one byte for byte and carry `Idempotent-Replayed: true`.
8. **Control.** On the same clean server and database, set the scenario up again and send the
   same request under a new key, uninterrupted. This is the answer the client would have got
   if nothing had crashed.
9. **Verify** (next section).

## What is checked

| Check | What it asserts |
|---|---|
| `crashed` | The request died at the named point: connection dropped, exit status 86 |
| `key_at_crash` | The key row sits at the last committed point |
| `resting_state` | The scenario's end state: confirm `succeeded` for 2000, capture `succeeded` with 1500 received (a partial capture, so a resume that recomputed the amount would show), cancel `canceled` with the acquirer's authorization voided, refund one `succeeded` refund of 500, create `requires_confirmation` |
| `ledger_invariants` | `Ledger::Invariants.check` (zero sum, balanced transactions, balances match entries) and a separate `Ledger::Checker.run`, with no violations and no drift |
| `acquirer_equals_ledger` | For **every** PaymentIntent in the database (setup, crashed and control), the simulator's books from `/admin/operations` agree with Clearinghouse's: at most one approved authorization, captured amount = the ledger's one capture transaction = `amount_received`, refunded amount = the ledger's refund transactions = `amount_refunded` = the succeeded refunds, and a canceled intent's authorization is voided |
| `one_event_per_change` | The events about the crashed request's objects (the intent, its charge, its refunds) have the same types in the same order as the control's, and no (object, type) pair appears twice |
| `same_response_as_control` | The recovered status and body equal the control's, after the normalisation below |
| `retry_replays_it` | A further retry replays the recovered answer byte for byte |
| `same_outcome_as_control` | Everything about the crashed intent equals the control's intent: its row, refunds, every event *with its payload*, ledger transactions with amounts, and the simulator's authorizations and operations, including the acquirer idempotency keys (so a resume that used attempt 2's key would show) |
| `nothing_left_locked` | No key is left unfinished, and no intent is left owned by a request |
| `rolled_back_phase_invisible` | before_commit cases only, see below |
| `recovered_without_detours` | Retry mode: every attempt before the answer was `409 idempotency_key_in_use` while the lease ran. No 5xx, and no other error |
| `completer_finished_it` | Completer mode: the completer finished the key, and the client's retry was a replay |
| `ambiguous_answer_resolved_by_asking` | The variant only, see below |

Comparing with a control request, rather than with values written into the harness, means
the harness does not need to know what the right response looks like. It only needs to know
that an interrupted request must end the same way as one that wasn't interrupted.

### What is normalised, exactly

Comparing the recovered response with the control's rewrites two things and nothing else:

1. **Generated ids** become `<prefix#n>`, numbered by first appearance within one document.
   These are Clearinghouse's `pi_`, `ch_`, `re_`, `evt_` and `req_` ids (prefix plus 24
   alphanumerics), the simulator's `acq_` references (24 hex), and the fake RiskGate's `asm_`
   assessment ids (a counter). The numbering keeps the references intact: a `latest_charge`
   pointing at the wrong charge, or an event about the wrong intent, still shows as a difference.
2. **The value of every key named `created`.** It is the Unix second the object was created,
   and the two runs create their objects at different times.

Status, every amount, every state, every error code and the key order must match exactly. The
retry-after-recovery comparison (`retry_replays_it`) normalises nothing. It compares bytes.

The outcome comparison also records which request's Idempotency-Key each event carries, so an
event credited to the wrong request would count as a difference. That holds in both modes,
because the completer rebuilds the original request's context (`Api::Completion`), including
its request id and key.

### before_commit: nothing of the rolled-back phase is visible

A crash inside a phase's transaction has to leave exactly what a crash right after the previous
phase's commit leaves. The harness tests that across cases. The snapshot at a
`P:before_commit` crash is compared with the snapshot at the `previous(P)` after-commit crash.
Both cases ran the same scenario, so their setups match. For `started:before_commit` the
comparison is with the case's own snapshot from before the request was sent.

A snapshot covers the merchant's key row (recovery point, whether it is leased, the stored
response code and the names of its `flow_state` entries), every intent (status, attempt,
amounts, ownership, whether it has a charge, risk verdict), refunds, event types in order, and
ledger transactions. Ids, times and lease tokens are normalised out. If a rolled-back phase
left any row, event or ledger line behind, this comparison would show it.

## The ambiguous acquirer

The hardest case in `idempotency.md` is an acquirer that committed and whose answer never
arrived. The variant `payment_intent.confirm:authorization_requested+acquirer_drop` puts it
right after a crash:

1. The armed server dies right after committing `authorization_requested`, so the acquirer
   hasn't been called yet.
2. Before recovery, the simulator is set to `drop_after_commit_rate: 1.0`. It commits every
   fresh operation, then closes the socket without a byte.
3. The first resume asks `GET /operations/<pi>:authorize:1` and gets `404`, so it authorizes.
   The simulator charges the card and drops the answer. The client gets
   `503 acquirer_unavailable` with `Clearinghouse-Should-Retry: true`.
4. The second resume asks again and gets `200` with the authorization, then records it. It
   sends **no** second `POST /authorize`.

The simulator's books look the same whether the resume asked or resent under the same key,
because the simulator replays either way. So the evidence comes from the recording proxy,
which logs every request the API sends to the acquirer (method, path, Idempotency-Key, and the
status or `dropped`). The check requires exactly one `POST /authorize`, which is the dropped
one, followed by a `GET /operations/...` answered `200`. The report keeps the full exchange
list for every stage of every case, which also shows, for example, that a resume at
`capture_recorded:before_commit` only asks and never recaptures.

## Recovery modes

- **retry** (default). The client resends the same request with the same key. While the dead
  process's lease runs (1 s here), it gets `409 idempotency_key_in_use` and waits 100 ms.
  After that the request resumes from its recovery point. In the recorded run the clean restart
  always took longer than the lease, so every case resumed on its first retry and none saw a
  409. The lease-refusal path is covered by `spec/integration/payments/idempotency_spec.rb`,
  not by this matrix.
- **completer** (`--recovery completer`). The harness runs `bin/completer --once` with the
  same environment as the server, at most three times, until the key is finished. Before each
  pass it waits until the key is the completer's to take, by the same rule as
  `Idempotency::Completer#candidates`: no live lease, and no run for the grace period, which
  defaults to the lock timeout. The ambiguous variant needs two passes, because the first gives
  its lease back after the lost answer. Only then does the client retry, and it must get the
  stored answer as a replay (`completer_finished_it`). `--completer "<command>"` swaps the
  command.

## What this does not cover

- **Crashes at recovery points only.** The hook fires on either side of a phase's commit, not
  in the middle of a foreign call. A crash while the acquirer is processing is the same, from
  the database's view, as a crash right after the `*_requested` commit (nothing recorded yet),
  and the variant covers the lost answer. A crash between two statements of one transaction is
  the same as `before_commit`, because Postgres rolls back the whole transaction.
- **One crash per request.** A crash during recovery (a crash of the resume) isn't covered.
  It's the same state as some earlier case, but the harness doesn't chain crashes to prove it.
- **Requests with a key only.** Keyless requests get a generated key that only the completer
  can finish. Completer mode could cover them, and the matrix doesn't do that yet.
- **Happy-path scenarios.** Every scenario uses `pm_card_visa`. A declined or risk-blocked
  confirm ends early: its phase goes straight to `finished`, so it reaches the same crash names
  by a different path. The matrix doesn't crash a declining request.
- **One request at a time.** Concurrency is experiment 1 and experiment 3.
- **A fake RiskGate.** The risk step is a real HTTP call to `bin/fake-riskgate`, which replays
  by key like RiskGate, with a 5 s deadline so a loaded machine can't turn an allow into a
  fail-open in one run and not the other. The real RiskGate isn't in the loop.

## Alternatives I didn't take

- **Raising an exception at the point instead of exiting.** It's cheaper, since there's no
  process restart. But `ensure` blocks, connection-pool cleanup and Sequel's transaction
  handling would all run, which is exactly what a real crash skips. `exit!` in a separate
  process is the closest thing to a power cut that a test can produce.
- **A database per case**, from a template. It's cleaner, but slower than one `TRUNCATE`. It
  also gains nothing, because the harness checks per object, and the check that looks at the
  whole database (`acquirer_equals_ledger`) is meant to include the setup and control intents.
- **Writing the expected outcome of each case into the harness.** That would be a second
  model of the flows that could be wrong in the same way the code is. Comparing with an
  uninterrupted control needs no model. The resting-state check keeps a few explicit values
  (status, amounts) as a floor.

## Results

Both recovery modes, on a machine shared with other jobs (load average 38 to 57 on 12 cores):

| Run | Mode | Commit | Headline | Wall time | Per case (min / median / max) |
|---|---|---|---|---|---|
| `20260924T010111Z-retry` | retry | bc17356 base, harness uncommitted | **crashed at 48 points across 5 flows, recovered at all 48** | 820 s | 8.9 / 17.2 / 24.5 s |
| `20260924T014550Z-completer` | completer | 96880c6 | **crashed at 48 points across 5 flows, recovered at all 48** | 743 s | 5.2 / 14.4 / 27.6 s |

The ambiguous variant passed in both runs, and so did all 24 before_commit rollback comparisons
in each. In completer mode, 10 cases needed no completer pass: the five `started:before_commit`
cases (no key row survived, so the client's retry ran afresh) and the five `finished` cases (the
response was already stored). 38 cases needed one pass, and the variant needed two. Most of the
time per case goes into the two API boots. The retry-mode report predates the `git` and
`api_process` fields. That run used Puma threads 1:4 and the default database pool of 10,
which the harness now sets explicitly.

## Cost and running it

```
bin/crash-matrix                          # the full matrix, retry mode
bin/crash-matrix --recovery completer     # needs bin/completer
bin/crash-matrix --only refund.create     # a partial run for development; no headline claim
```

Most of the time goes into booting the API twice per case (Puma plus the whole app and
sorbet-runtime). The report records every stage's time per case, the load average before and
after, the command, the machine and the Postgres version. A case never depends on timing
beyond the 1 s lease. On a loaded machine the run is just slower. The results don't change.
