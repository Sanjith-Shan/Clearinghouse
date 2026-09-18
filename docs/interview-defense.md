# Interview defense

The ten questions from the spec's "Interview defense" section, answered from this repo's code
and docs, with file and line pointers into the branch these notes were written on (`main`
plus `pr/integrate-fix-main`). Line numbers drift as code changes, so each pointer also names
the method. Where something is not built, or not merged here, the answer says so.

Study order: 1, 2 and 5 first, since everything else leans on them.

## 1. Draw the confirm flow with its recovery points, and say what a crash at each does

The drawing is in `DESIGN.md` ("Confirm, point by point") and `docs/design/idempotency.md`.
Points, in order: `started`, `intent_locked`, `risk_assessed`, `authorization_requested`,
`authorization_recorded`, `ledger_posted`, `finished`.

How it is built:

- The flow is data: `Payments::Flows::ConfirmIntent#phases`
  (`lib/clearinghouse/payments/flows.rb:139`). Each `Phase` has an optional foreign step
  (run with no transaction open) and an atomic step. `lock_phase` (`:159`) moves the intent to
  `processing` and bumps `attempt`. `risk_phase` (`:172`) calls RiskGate, then stores the
  verdict. A checkpoint phase commits `authorization_requested` before the acquirer is called.
  `authorize_phase` (`:184`) calls the acquirer, or asks it, and records the answer.
- The runner executes a phase in `Runner#run_phase` and `#commit_serializable`
  (`lib/clearinghouse/idempotency/runner.rb:221`, `:246`). The atomic step and the move of the
  key's `recovery_point` commit in one SERIALIZABLE transaction.
- Every commit is conditional on the lease: `Store.advance!` updates
  `WHERE id = ? AND lock_token = ? AND recovery_point = ?` and raises `LockLostError` if it
  touched no row (`lib/clearinghouse/idempotency/store.rb:115`). That is a fencing token. A
  request that stalled past its lease cannot commit over the one that took over.
- The crash hook fires just before and just after each commit (`runner.rb:263`, `:266`). It
  is armed only when `CLEARINGHOUSE_ENV` is `test` or `experiment`
  (`lib/clearinghouse/idempotency/crash_hook.rb:90`), and it calls `Process.exit!`, which
  skips `ensure` blocks, the closest a process gets to losing power.

What a crash right after each commit leaves, and what resumes it (the client's retry with the
same key, or `bin/completer`, via `Idempotency::Completer`,
`lib/clearinghouse/idempotency/completer.rb:18`):

| Crash after | What is durable | Resume does |
|---|---|---|
| `started` | a leased key row | runs everything from the start |
| `intent_locked` | intent `processing`, attempt N | asks RiskGate again with the same key `<pi>:N`. RiskGate replays, and nothing acted on the first answer |
| `risk_assessed` | the verdict | goes to the acquirer. RiskGate is not asked again |
| `authorization_requested` | "the acquirer may have been asked" | asks `GET /operations/<pi>:authorize:N` first, and authorizes only on "nothing under that key" |
| `authorization_recorded` | the acquirer's answer | applies it: status, ledger, events |
| `ledger_posted` | the money | renders and stores the response |
| `finished` | the stored response | replays it byte for byte |

A crash *inside* a transaction rolls back that phase, which leaves the previous row. The
specs: `spec/idempotency/crash_hook_spec.rb` (in-process, a toy flow crashed at every point),
`spec/integration/payments/completer_spec.rb` and `bin_completer_spec.rb`. Experiment 2 does
it with real processes for every point of every flow: `bin/crash-matrix`
(`docs/design/crash-matrix.md`). The development runs recovered at all 48 points across 5
flows. The final run, which also covers `review.reject`, is pending, so quote that one.

Be ready for: "why is `authorization_requested` its own commit with no work in it?" Because
it is the promise that from here on the acquirer may know about this attempt. Without it, a
resume could not tell "never sent" from "sent, answer lost", and would have to guess.

## 2. Why the ambiguous acquirer timeout is the hardest case, and how it is resolved

The acquirer charged the card and the response never arrived. From the caller's side that
looks the same as a request that never landed. Treat it as "nothing happened" and either the
customer is charged while the merchant is told no, or a retry under a new key charges them
twice. Brandur's post leaves this case to the processor's own idempotency.

How Clearinghouse resolves it:

1. **Classify by phase, not by exception.** `Acquirer::Client#exchange`
   (`lib/clearinghouse/acquirer/client.rb:176`) opens the connection first (`http.start`,
   `:186`). A failure there means no byte was sent, so it is `Unavailable`. Any failure after
   the connection is up is `Unknown` (`:193`), even a reset that probably means the server never
   read it, because the client cannot be sure. A 503 is `Unavailable` (the simulator's contract
   is to decide 503 before touching its books), any other 5xx is `Unknown` (`:148`, `:149`).
   `max_retries = 0` (`:184`) stops Net::HTTP from silently resending a POST.
2. **Keys derived from the payment, never random.** `PaymentIntent#authorization_key` is
   `"#{id}:authorize:#{attempt}"` (`lib/clearinghouse/payments/payment_intent.rb:72`).
   Whoever resumes can compute the key the first run used. Refunds use the `re_` id
   (`lib/clearinghouse/payments/refund.rb:129`).
3. **Unknown changes nothing.** The phase raises a retryable `503 acquirer_unavailable` before
   its transaction, so the key stays at `authorization_requested` and the intent stays
   `processing`.
4. **Resume asks first.** `Flows.definite` (`flows.rb:35`): on a resumed phase it calls the
   status query. Approved or declined is recorded as if the answer had arrived. `NotFound`
   means the acquirer committed nothing, so it sends now, under the same key. No answer to the
   question is another retryable 503.
5. **Attempt is bumped once per confirmation.** `Confirm.lock!`
   (`lib/clearinghouse/payments/confirm.rb:31`) is the only place it changes, and a resumed
   request is already past `intent_locked`. A new attempt only comes from a new confirm after a
   definite decline.

Specs against the real simulator: `spec/integration/payments/idempotency_spec.rb:136`
(`pm_card_timeout` charged exactly once), `:150` (dropped after commit, any card), `:159`
(never reached the acquirer, so `NotFound` and then authorize under attempt 1's key), `:170`
(the status query itself unanswered), `:180` (a lost decline resolves to the same decline).
Experiment 1 is this case under load (`docs/design/storm.md`). Its final numbers are pending.

Why ask instead of resending under the same key, when the simulator would replay anyway: resume
never sends a mutation it cannot show is needed, a status query is a read the completer can
repeat on a schedule without an issuer counting another attempt, and the decision is explicit
and tested rather than hidden inside the acquirer's replay.

## 3. Why SERIALIZABLE (or why not), with the numbers from experiment 3

**The numbers are not in yet.** `bin/exp-isolation` is built and its anomaly definitions are
tested (`spec/experiments/isolation_spec.rb` forces each interleaving with two connections),
but the timed runs wait for a quiet machine (`docs/design/isolation.md`, status note). Do not
quote a throughput figure until `results/exp3-isolation/results.json` exists.

What ships today, and the argument:

- Every atomic phase runs SERIALIZABLE: `Serializable.transaction`
  (`lib/clearinghouse/idempotency/serializable.rb:67`), up to 8 attempts (`:20`) with
  full-jitter backoff capped at 250 ms (`:80`). It refuses to nest inside another transaction,
  where Postgres would ignore the isolation level and a retry would redo half the work.
- Inside, the payments code locks the rows it checks: `PaymentIntents.lock!`
  (`lib/clearinghouse/payments/payment_intents.rb:37`), and payouts read the balance with
  `Ledger.balance_for_update` (`lib/clearinghouse/ledger.rb:44`).
- Refunds of one payment also queue on an advisory lock before their transaction begins,
  `Turnstile.through` (`lib/clearinghouse/idempotency/turnstile.rb:30`), wired by
  `queue_on` on the refund phases (`flows.rb:101`, `:336`).
- Running out of retries is a retryable `409 lock_timeout`, not a 500
  (`lib/clearinghouse/api/app.rb:157`).

The argument: `FOR UPDATE` protects exactly the rows you remember to lock. SERIALIZABLE also
protects checks that are not one row: a sum, "is there another pending refund", anything where
the conflicting write is an insert. It costs retries under contention. The lock inside keeps
those short, because the loser waits instead of doing its work twice. A detail worth knowing
cold: under SERIALIZABLE, a transaction that waited on `FOR UPDATE` still gets 40001 when the
winner commits, because its snapshot predates the winner's write. The lock turns a race into a
queue but does not remove the retry. That is why the turnstile exists, and it came from a real
bug (question 6).

The four strategies experiment 3 compares, and what each allows, are in `isolation.md`:
read-then-write loses updates and over-refunds, `FOR UPDATE` and both SERIALIZABLE variants
should show zero anomalies, and the question the numbers answer is what SERIALIZABLE costs on
top. If `FOR UPDATE` alone is anomaly-free and clearly faster, the honest answer is to say so,
with the ops/s and retries per 100 operations, and say which one ships and why.

## 4. Walk a refund through the ledger, entry by entry, and show where it clears

A $40.00 refund of a $100.00 payment, with our 2.9% + 30 cents fee.

1. `POST /v1/refunds` runs the `refund.create` flow, `CreateRefund#phases` (`flows.rb:329`):
   `started -> refund_created -> refund_requested -> refund_recorded -> finished`.
2. `refund_created`: `Refunds.reserve!` (`lib/clearinghouse/payments/refund.rb:93`) locks the
   intent, checks the state machine allows `refund`, checks the amount against
   `amount_received - amount_refunded`, inserts the refund `pending`, and adds 4000 to
   `amount_refunded`. That is the reservation. Nothing is in the ledger yet. The database
   backs it with `CHECK (amount_refunded <= amount_received)`.
3. `refund_requested` commits, then the acquirer is asked to refund under the key `re_...`
   (`refund.rb:129`).
4. `refund_recorded`: `Refunds.record!` (`refund.rb:144`) on approval posts one ledger
   transaction under flow `re_...` from `Ledger::Flows.refund`
   (`lib/clearinghouse/ledger/flows.rb:83`):

   | Account | Debit | Credit |
   |---|---|---|
   | `merchant:<id>:available` | 40.00 | |
   | `platform:refund_clearing` | | 40.00 |

   Our fee is not returned (policy in `docs/design/ledger.md`). Available may go negative if
   the payment's funds are still pending, which the demo shows (-40.00 before release).
5. The flow is now **OPEN**: `refund_clearing` holds 40.00 for this flow. `bin/explain re_...`
   shows it (the demo prints it).
6. It clears when the acquirer's settlement file carries the refund line. The reconciler
   posts `Ledger::Flows.refund_settled` (`flows.rb:90`):

   | Account | Debit | Credit |
   |---|---|---|
   | `platform:refund_clearing` | 40.00 | |
   | `platform:cash` | | 40.00 |

   `refund_clearing` is back to zero within the flow, so the flow is **EXPLAINED**.

The reconciler posts it from the `refund` line of the settlement file, matched by the
acquirer's operation id (`lib/clearinghouse/reconciliation/ingestor.rb:256`,
`docs/design/reconciliation.md`, "Matching a line to a flow"). `bin/demo` shows the refund
OPEN before the file is ingested and EXPLAINED after.

Where "cleared" is computed: `Ledger::Clearing.report` (`lib/clearinghouse/ledger/clearing.rb:127`)
sums each clearing account per flow id. A flow is explained when all of them net to zero.

## 5. What the deferred constraint trigger checks, and why it is deferred

Code: `db/migrations/20260923120000_ledger.rb:152` (`ledger_check_transaction`) and the two
constraint triggers at `:195` and `:197`.

What it checks, for each ledger transaction written in the database transaction being
committed:

- at least two entries;
- debits minus credits is zero **in every currency separately**;
- if the transaction is a reversal, its entries exactly mirror the original's on every account.

Why deferred: a posting is several INSERT statements. The header row goes in first, because
entries reference it, and at that moment the transaction has zero entries. A check that ran per
statement would reject every valid posting. At COMMIT the transaction is complete, which is the
only moment "balanced" means anything. It fires from both tables so a header with no entries,
which would never fire an entries trigger, is caught too. A session can make it stricter with
`SET CONSTRAINTS ALL IMMEDIATE` but cannot turn it off.

What sits next to it, and why the database is the backstop at all: Ruby validates first
(`Ledger::Posting#validate!`, `lib/clearinghouse/ledger/posting.rb:84`, raising
`UnbalancedError` with the exact imbalance). The database checks again because Ruby only sees
writes that go through `Ledger.post!`, and the database sees every writer. The same migration
also rejects UPDATE, DELETE and TRUNCATE by trigger (`:81`), grants the app role only SELECT and
INSERT on history (`:202`), and stamps each header with the creating transaction id
(`created_xact`, `:106`) so nobody can append a balanced pair to last week's transaction.

The proofs, all raw SQL with no Ruby ledger code: `spec/db/ledger_schema_spec.rb:43` (an
unbalanced insert passes each statement and fails at COMMIT), `:60` (per currency, not in
total), `:84` and `:89` (zero and one entry), `:94` (IMMEDIATE fails at once), `:106` (no
entries appended later), `:136` to `:150` (append-only by trigger for the owner and by privilege
for the app).

## 6. A bug from the bug log: how it was caught and what the fix was

Two are worth telling. Know one of them in full.

**Concurrent refunds ran out of serialization retries**
(`docs/bugs/payments-concurrent-refunds-exhausted.md`). Every refund writes its intent's
`amount_refunded` twice, in two SERIALIZABLE phases that lock the intent. Under SERIALIZABLE, a
waiter on that lock still aborts with 40001 when the winner commits, and with enough refunds
queued the last in line lost all 8 attempts. `ExhaustedError` reached the generic handler as a
500. Caught by `spec/api/refunds_spec.rb` ("never refunds more than was captured under
concurrent refunds", now at `:106`), which returned `{200=>5, 500=>2, 400=>3}` on a loaded
machine. Reproduced with 16 refunds of 100 on a 1,600 payment: 5 to 10 responses of 500 per
run, 157 to 174 retries. Fix, 97d8424: phases that write the intent pass an advisory-lock
turnstile before their transaction begins (`turnstile.rb:30`), so each starts after the previous
committed, and exhaustion anywhere became a retryable 409 (`app.rb:157`). After: 16 of 200 in
all five runs, with 40 to 52 retries per run. Specs `:120` and `:130` hold both behaviours.

**A payment smaller than the acquirer's fee could never be settled**
(`docs/bugs/model-settlement-fee-over-gross.md`). Caught by experiment 4, not by a hand-written
test. `bin/model-test --sut ledger --seed 1` failed at step 56 of sequence 130 and shrank to five
steps: a 1 fils KWD payment, confirm, two days, settle. The acquirer's fee (10 fils) exceeded
the payment, `Flows.settlement` built a negative cash debit, and `post!` refused it, so the
capture would sit in `processor_receivable` forever. Fix, 8e5a49a: credit cash for the
difference when the fee exceeds the gross. It is still an open policy question whether such
payments should be accepted at all.

The full index, one line each, is at the end of `DESIGN.md`.

## 7. At-least-once delivery, and why exactly-once over HTTP is not on offer

The window: a worker POSTs, the endpoint answers 200, and the worker dies (or loses its database
connection) before it records success. The lease expires and another worker sends the event
again. `spec/webhooks/worker_spec.rb:252` does exactly this and sees the server receive the
event twice.

Why it cannot be closed from the sending side: exactly-once delivery would need the endpoint's
side effect and our "delivered" record to commit atomically, and they live in two systems that
share no transaction. Recording before sending moves the window and makes it a lost event
instead of a duplicate, which is worse. Timeouts make it worse in the other direction: a
request that timed out on our side may have been processed on theirs. What can be had is
exactly-once *processing*, and that is the receiver's job: dedupe on the event id. RiskGate
does.

The pieces:

- The outbox. Events are written by `Events.emit!` inside the transaction of the state change,
  so an event exists if and only if the change committed (`docs/design/payments.md`, "The
  outbox").
- The queue. Workers claim with `FOR UPDATE SKIP LOCKED` and a lease
  (`lib/clearinghouse/webhooks/queue.rb:79` for the FIFO baseline, `:127` for the isolated
  claim, which runs as one PL/pgSQL call from
  `db/migrations/20260924140000_webhook_claim_function.rb`).
- Recording. `Worker#record_success` (`lib/clearinghouse/webhooks/worker.rb:150`) records a 2xx
  whoever holds the lease now, because the endpoint having the event is the fact that matters.
  A failure counts only if the worker still holds the lease.
- Retries: full jitter, `uniform(0, min(12 h, 60 s * 2^(n-1)))`, stopped after three days
  (`docs/design/webhooks.md`, "Retries").

Experiment 6 measures the duplicate rate with worker processes killed at random. That run has
not been done yet.

## 8. DNS rebinding, and why "resolve, check, then connect by hostname" is broken

The attack: the merchant registers `https://rebind.attacker.example/hook`. The attacker's DNS
server answers the first lookup with a public address and the second with 127.0.0.1, TTL 0. A
sender that resolves the name, checks the address, and then hands the *name* to its HTTP client
has done two lookups. The check saw the public address, and the connection goes to the internal
one.

What `SafeHttp` does instead (`lib/clearinghouse/webhooks/safe_http.rb`):

- Parse strictly first (`Egress::Target`): https only, no userinfo, only canonical dotted-quad
  IPv4 (so `2130706433`, `0177.0.0.1` and `127.1` are refused before DNS).
- Resolve once, itself (`addresses_for`, `:107`, `@resolver.resolve` at `:111`), and check
  **every** address with `Egress::IpPolicy`. If any is internal the delivery is blocked, even
  if another is public.
- Connect to the address it checked: `Net::HTTP.new(host, port, nil)` then
  `http.ipaddr = pinned.address` (`:155`, `:156`). Net::HTTP opens the socket to `ipaddr`
  while SNI, the certificate hostname check and the `Host` header still use the name. The `nil`
  proxy argument matters: the default would honour a proxy from the environment.
- Never follow redirects, and check again at send time, since DNS can change between
  registration and delivery.

The proof is a counterexample in the spec, `spec/unit/webhooks/safe_http_spec.rb:177`: a fake
resolver that rebinds, and a fake network where connecting by name resolves through it. A naive
check-then-`Net::HTTP.start(hostname)` client resolves twice and posts to the internal server
(`:216`). `SafeHttp` resolves once, connects to the public address, and the internal server
receives nothing (`:224`). The address policy also covers IPv4-mapped IPv6 (`::ffff:127.0.0.1`
is loopback on a dual-stack socket, so the whole range is refused), NAT64 and 6to4 by their
embedded address, CGNAT and the metadata address 169.254.169.254.

Source for the approach: the Smokescreen README (reading list item 6), which blocks by resolved
IP rather than by hostname.

## 9. How a version change module turns a new response into an old one

Core code only ever produces the latest shape. `Versioning::Engine#render`
(`lib/clearinghouse/versioning/engine.rb:56`) then:

1. copies the object (the caller's hash is never modified);
2. expands the caller's `expand[]` paths, then every field a skipped change forces to be
   embedded (`forced_expansions`);
3. applies every change newer than the requested version, newest first, each one walking the
   whole tree (`apply`, `:100`) and transforming every object whose `object` is one of the
   change's resources. The walk reaches top-level objects, list items, event payloads and
   embedded objects, so a change is written once per resource, not once per place it appears.
   `metadata` is skipped so merchant data comes back verbatim.

A change is a class that overrides `version`, `description`, `resources` and `transform`. The
three that shipped:

- `2026-03-01`, `AmountReceivedRename`
  (`lib/clearinghouse/versioning/changes/amount_received_rename.rb:23`): renames
  `amount_received` back to `amount_captured`, keeping the key's position.
- `2026-06-01`, `LastPaymentErrorObject` (`last_payment_error_object.rb:25`): splits the
  `last_payment_error` object back into flat `failure_code` and `failure_message`, and drops
  `decline_code`, which old clients never received.
- `2026-09-01`, `ExpandablePaymentMethod`: `payment_method` became an expandable id. Going back
  needs the full object, which the transform cannot load. So the change declares a forced
  expansion, and the engine expands it through the same loader as `expand[]=payment_method`
  *before* any transform runs. Transforms stay pure functions of their input.

Guard rails: after every transform, `transform_one` (`engine.rb:111`) compares the protected
fields (`id object amount currency payment_intent reason status`, `:30`) before and after and
raises `ProtectedFieldError` on any change. RiskGate reads webhooks at its pinned version and
depends on them. Golden files pin every fixture at every version
(`spec/versioning/golden_spec.rb`, `spec/fixtures/golden/<version>/`). Webhooks go through the
same engine per endpoint version (`render_event`), so two endpoints on different versions get
two bodies for one event id. The changelog is generated from the modules
(`bin/changelog`, `docs/api-changelog.md`).

Source: Brandur Leach, *APIs as infrastructure* (reading list item 4). Stripe uses a small DSL.
These are plain method overrides, so Sorbet checks each against the abstract class.

## 10. Given a failing model-based sequence, find the bug live

Practise this one with the planted bugs. They are deliberate, live in
`lib/clearinghouse/testing/model/planted_bugs.rb`, and are injected into the ledger system under
test without touching the real classes.

```
bin/model-test --sut ledger --plant fee_rounding --sequences 50 --max-length 60 --seed 1
```

What happens: the generator (`generator.rb`) produces weighted random operations from the
model's state, legal and illegal. After every step the checks run in order
(`Checks.first_violation`, `lib/clearinghouse/testing/model/checks.rb:26`): outcome, balances,
zero sum per currency, refunds within captures, completed flows cleared, open flows, and the
ledger's own invariants. On a failure the shrinker (`shrinker.rb:44`) cuts everything after the
failing step, runs delta debugging over the list (`ddmin`, `:86`), then shrinks the numbers
toward round values (`shrink_numbers`, `:126`). A candidate counts only if it fails the same
check, so shrinking cannot slide to a different bug. The result is written as a replay script
(`Script.replay`, `script.rb:47`) to `results/exp4-model/<run>-repro.rb`.

The recorded run shrank 47 steps to 3 in 68 runs:

```
create_merchant(fee 2.9% + 30c), create_intent(amount: 500, usd), confirm(pm_card_visa)
step 3 failed check balances:
  merchant:m1:pending (usd): model 456, system 455, off by -1
  platform:fee_revenue (usd): model 44, system 45, off by 1
```

How to debug it out loud: the fee is one cent high on $5.00. 2.9% of 500 is 14.5, plus 30 is
44.5. The model rounds half-even to 44 and the system says 45, so the system rounds half up. The
shrinker tried round amounts below 500 first and none failed, which is itself the hint: 500 is
the smallest USD amount whose 2.9% ends in exactly .5. The planted change is
`FEE_ROUNDING` (`planted_bugs.rb:20`).

The second planted bug, `--plant payout_failed_skips_clearing`, is harder: a failed payout
returns money out of cash instead of out of `payout_clearing`. It balances, so the database
accepts it, and only the model's balance check (and the open-flows check) sees it. It shrank to
seven steps, including a payout of 13 (the simulator's failure rule, which the shrinker found by
trying 13 first). Both are written up in `docs/design/model-testing.md`, "Planted-bug demo".

The real bug this harness found is question 6's second story.
