# Experiment 1: the retry storm

Code: `bin/storm`, `sim/experiments/storm.rb` (driver and counting), `sim/experiments/storm.ru`
(the server it runs), `lib/clearinghouse/experiments/storm_baselines.rb` (the two baselines),
`spec/experiments/storm_spec.rb`. Results: `results/exp1-retry-storm/`.

The question: when many clients send the same confirm at once, and the acquirer sometimes
charges the card and then loses the answer, how many cards are charged twice? The spec asks
for three implementations, charges counted from the acquirer's books rather than ours, and a
number for the naive version that is measured, not assumed.

## Method

Everything crosses a real socket. `bin/storm` starts:

- the acquirer simulator, `bin/sim`, as its own process, with `drop_after_commit_rate = R`.
  A dropped request commits its operation and then closes the socket without writing a byte
  (`sim.md`, "Dropping the connection after commit"). `Acquirer::Client` reports that as
  `Unknown`. The card was charged and nobody was told.
- the API on Puma (16 threads and a DB pool of 16 by default), built by
  `sim/experiments/storm.ru` with `CLEARINGHOUSE_ENV=experiment`. It serves the real routes
  and the two baselines. RiskGate is not wired in: risk is not what this measures, and a risk
  call would add the same noise to all three.

Then for each implementation:

1. Reset the simulator and set its seed, drop rate and latency. The seed is the same for all three.
2. Create a merchant and N PaymentIntents (USD 20.00, automatic capture) through `POST
   /v1/payment_intents`. This part is not timed.
3. For each intent, start K threads. Each has its own `ClearinghouseClient::Client`, the real
   one, with `max_network_retries` 10. It retries connection failures, 409 and 5xx with
   exponential backoff and full jitter, and it always sends the same Idempotency-Key. All K
   threads wait at a gate, and the gate opens only once every one of them is waiting. That
   way all K requests are in flight together, which gives the naive version its widest
   window. P intents (default 4) are stormed at a time.
4. Keep what each client was finally told: the status and body of its last HTTP attempt, and
   the status of every attempt.
5. Count:
   - **charges**: captured authorizations per intent, from the simulator's own books
     (`GET /admin/operations`, `charges_by_reference`). A **double charge** is an intent with
     more than one.
   - **ledger captures**: `capture` transactions per intent in `ledger_transactions`.
     "Charged, not in ledger" means the acquirer captured more than the ledger recorded.
   - **identical bodies**: the share of intents whose K clients got byte-identical bodies.
   - **truthful answers**: the share of clients whose answer matches the acquirer. A client
     told `succeeded` must have been charged, and a client told anything else must not
     have been. This catches a case identical bodies miss: every client can agree on a
     wrong answer.
   - **stuck processing**: intents left in `processing`.
   - `Ledger::Invariants.check` over the whole database.

The report records the command line, the machine, `uptime` before and after, the server's
threads and pool, and the full plan. Runs are labelled `smoke` unless `--label full` says
otherwise.

## The three implementations

All three run the same confirm steps: `Confirm.lock!` (requires_* to processing, attempt + 1),
`record_risk!`, the authorization under `PaymentIntent#authorization_key`
(`<pi>:authorize:<attempt>`), `record_authorization!` and `apply_approval!`. They also use the
same `SERIALIZABLE` transactions with retry and the same response rendering. The only
difference is the idempotency layer.

| | none | naive | clearinghouse |
|---|---|---|---|
| Idempotency-Key | ignored | looked up, then the response inserted after the work | a key row inserted first, under a unique index, and leased for the request |
| A duplicate while the first is running | runs | runs (the lookup found nothing) | `409 idempotency_key_in_use`, and it never touches the intent |
| The acquirer's answer lost | the attempt fails, or the intent is held (see below) | same | the key stays at `authorization_requested`, `503`, and the retry resumes and asks `GET /operations/<key>` |
| What is stored | nothing | 2xx and final 4xx, as in the real rule | 2xx and final 4xx |

The baselines exist only to be measured against. They live in
`lib/clearinghouse/experiments/storm_baselines.rb`, under
`/experiments/none/v1/payment_intents/:id/confirm` and `/experiments/naive/...`, and nothing
in production can reach them. `config.ru` never loads the file, and
`StormBaselines.rack_app` refuses to build unless `CLEARINGHOUSE_ENV=experiment` (a spec
checks it refuses `production` and `test`). The naive table,
`experiment_naive_idempotency_keys`, is not in `db/migrations`. `bin/storm` and the spec
create it.

### What a baseline does when the answer is lost

Without recovery points, nothing will ever finish an attempt whose answer was lost. A
system built that way has two choices, and `--baseline-on-unknown` measures each of them:

- **fail** (the default): end the attempt. The intent goes back to `requires_payment_method`
  with `last_payment_error.code = acquirer_unavailable`, so the customer can try again. This
  is what a system with no completer must do if the customer is to be able to pay at all.
- **hold**: leave the intent `processing` and answer 503. Nothing charges twice, and nothing
  ever records the charge that did happen.

I chose fail as the default because it is the failure the Stripe post describes. Hold is
the other half of the same problem, and the smoke runs show that it just moves the damage
elsewhere.

## Why each baseline fails

**none, with fail.** Clients C1..C8 are released together.

1. R1 wins the row lock in `Confirm.lock!` and moves the intent to `processing`, attempt 1.
   R2..R8 wait on the row. Under SERIALIZABLE they then get a serialization failure, retry,
   find `processing`, and answer `400 payment_intent_unexpected_state`. That answer is final,
   so their clients stop.
2. R1 authorizes under `pi_X:authorize:1`. The simulator captures and hangs up, and
   `Acquirer::Client` says `Unknown`.
3. R1 fails the attempt (`processing` to `requires_payment_method`) and answers 503.
4. C1 retries. The key is ignored, so this is a new confirm. `lock!` starts attempt 2, and
   the authorization under `pi_X:authorize:2` is a new key, so the acquirer captures again.

Result: two charges, one ledger capture (the first charge was never recorded), and seven
clients told the payment is in an unexpected state while the eighth is told it succeeded. A
duplicate whose jittered serialization retries land after step 3 can start attempt 2 itself,
and that also happens.

**naive, with fail.** The lookup takes no lock and marks nothing. All eight requests look
before any of them inserts, so all eight run the work, and the key protects nothing while
the first request is running. The state machine turns seven of them into 400s, as above. The
first answer inserted under the key wins, and it is usually one of those 400s, because they
finish long before the winner's acquirer call does. From there:

- If the winner's answer was lost, its client's retry finds the stored 400 and replays it.
  The card was charged, the intent went back to `requires_payment_method`, and every client
  is told "unexpected state". That is charged and not in the ledger, with all eight bodies
  identical and all eight wrong.
- If a request that passed the lookup reaches `lock!` only after the winner has failed the
  attempt (its serialization retries put it there), it starts attempt 2 and charges the card
  again. That is the check-then-act race, and it produced the naive version's double charges.

So the naive version double charges less than none. It is not safer, though: it replaces a
double charge with a charge the merchant never hears about.

**Both, with hold.** No second attempt ever starts, so there is no double charge. Every lost
approval leaves a charged card, an intent stuck in `processing`, and clients told 400 or
503. That is exactly as many "charged, not in ledger" as there were drops.

**Contention.** The seven duplicates keep hammering the intent row, and sometimes the
winner's own `apply_approval!` runs out of serialization retries and fails with a 500 after
the acquirer has captured. That leaves a charged intent stuck in `processing` even under
fail. I saw this in an exploratory run with `--request-log`
(`Serializable::ExhaustedError` from the baseline's `apply_approval!` step). In Clearinghouse
the duplicates stop at the key and never touch the row.

**Clearinghouse.** The key row is inserted in its own transaction under a unique index, so
exactly one request holds it and the others get 409 and back off. When the acquirer's answer
is lost, the key stays at `authorization_requested` and the lease is given back. The next
retry, from any of the eight clients, resumes there, asks `GET
/operations/pi_X:authorize:1`, gets the approval, and records it. The attempt number never
moves, so no second authorization exists. Every later request replays the stored bytes.

## Results (smoke)

**These are smoke runs:** 20 intents × K = 8 on a shared machine with a load average of 50
to 70 on 12 cores. They show the mechanisms. They are not the headline numbers. Drops are
drawn per request from the simulator's seeded RNG, but thread timing decides the request
order, so repeated runs differ in detail.

Baselines on a lost answer: **fail** (`results/exp1-retry-storm/20260924T011042Z-smoke-fail/`)

| impl | intents | K | drop rate | requests | HTTP attempts | double charges | extra charges | charged, not in ledger | stuck processing | ledger captures per intent | identical bodies | truthful answers | ledger invariants | wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| none | 20 | 8 | 0.2 | 160 | 167 | 5 | 5 | 7 | 2 | 0: 2, 1: 18 | 0.1 | 0.1125 | hold | 11.676 |
| naive | 20 | 8 | 0.2 | 160 | 166 | 2 | 2 | 6 | 1 | 0: 4, 1: 16 | 0.2 | 0.1 | hold | 5.59 |
| clearinghouse | 20 | 8 | 0.2 | 160 | 525 | 0 | 0 | 0 | 0 | 1: 20 | 1.0 | 1.0 | hold | 17.498 |

Baselines on a lost answer: **hold** (`.../20260924T011155Z-smoke-hold/`, baselines only)

| impl | intents | K | drop rate | requests | HTTP attempts | double charges | extra charges | charged, not in ledger | stuck processing | ledger captures per intent | identical bodies | truthful answers | ledger invariants | wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| none | 20 | 8 | 0.2 | 160 | 165 | 0 | 0 | 5 | 5 | 0: 5, 1: 15 | 0.25 | 0.0938 | hold | 6.471 |
| naive | 20 | 8 | 0.2 | 160 | 165 | 0 | 0 | 5 | 5 | 0: 5, 1: 15 | 0.25 | 0.0938 | hold | 5.982 |

How to read them:

- Clearinghouse charged every card exactly once. The ledger agrees, all 160 clients got
  byte-identical, truthful `200 succeeded` bodies, and nothing is left in `processing`. Its
  extra HTTP attempts (525 for 160 calls) are the 409s the duplicates get while the first
  request runs, and wall time is the clients' backoff, not server work.
- A truthful-answer rate near 0.1 for the baselines means about one client in eight (the
  winner) is told the truth. The rest are told "unexpected state" about a payment that
  went through.
- The ledger invariants hold in every run. The ledger balances even when it is wrong about
  the world: a double charge the ledger never saw breaks no invariant. That is why the
  experiment counts charges from the acquirer's books.

The full run is for a quiet machine, in one command:

```
bin/storm --impl all --intents 1000 --concurrency 16 --drop-rate 0.1 --seed 1 --label full
bin/storm --impl all --intents 1000 --concurrency 16 --drop-rate 0.1 --seed 1 --label full --baseline-on-unknown hold
```

It creates and migrates its database (`CLEARINGHOUSE_DB`, default `clearinghouse_storm`) if
needed, starts and stops its own processes, and writes `results.json` and `results.md` to a
new timestamped directory. `--acquirer-latency 50,400` adds acquirer latency (lognormal
p50/p99 in ms), and `--parallel`, `--server-threads` and `--db-pool` set the concurrency.

## The spec

`spec/experiments/storm_spec.rb` runs the same Runner against the simulator and the API,
both on Puma in the spec process, with 2 intents × K = 4 and a drop rate of 1.0, which
makes the result deterministic: every intent's first authorization is charged and its
answer lost. It checks that Clearinghouse gives 0 double charges, one acquirer capture and
one ledger capture per intent, eight byte-identical `200` bodies and ledger invariants that
hold. It also checks that `none` gives 2 double charges out of 2. The second check proves
the counter can see a double charge at all, since a counter that always said zero would
pass the first. It also checks the environment guard and the tally on hand-made inputs.

## Limits

- One process each, on one machine, with the simulator's latency at 0 by default.
  Real acquirer latency widens the window between a naive lookup and its insert, but it also
  makes the duplicates' 400s land even earlier relative to the winner. The option exists so
  the full run can report both.
- The simulator replays under the same key, so any retry that reuses attempt N's key is safe
  at the acquirer. Every double charge above comes from a *new attempt* (a new key), which
  is the realistic failure. In the JSON, the histogram of acquirer captures per intent
  matches the histogram of confirm attempts per intent in every baseline run.
- The baselines are my implementation of "without the idempotency layer". I kept them as
  close to the real flow as I could, and the choice of what they do on a lost answer is
  explicit and measured both ways.
