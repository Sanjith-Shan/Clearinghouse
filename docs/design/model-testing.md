# Model-based testing (experiment 4)

Code: `lib/clearinghouse/testing/model/`, specs: `spec/model/`.

The unit tests of each area check the cases their author thought of. This harness checks
the ones nobody thought of. It generates long random sequences of API operations
(create, confirm, capture partially, cancel, refund partially, let disputes open, win or
lose them, pay out, advance the clock, settle, sweep available funds), runs each sequence
against a plain-Ruby **reference model** and against the real system side by side, and
after **every step** asserts that the two agree and that the global invariants hold. When
a step fails, it shrinks the sequence to a minimal one and prints it as a Ruby script
that replays the failure.

## Where it lives, and why under `lib/`

The harness is test tooling: nothing in the service requires it, and `lib/clearinghouse.rb`
does not load it. It still lives in `lib/clearinghouse/testing/` rather than `spec/`,
because:

- **Sorbet checks it.** Everything under `spec/` is `typed: false`. The model is the
  specification the real code is held to, so it gets `typed: true` and sigs like the code
  it judges.
- **`bin/model-test` and reproduction scripts load it outside RSpec**, and a script that
  requires a file under `spec/` would drag RSpec's configuration along.

## The reference model

`ReferenceModel` holds merchants, payment intents (status, amount, capturable, received,
refunded, capture method), refunds, disputes, payouts, per-merchant per-currency balances
(pending, available, held), the platform accounts (cash, receivable, the three clearing
accounts, fee revenue, dispute fee revenue, processing expense), pending settlement
movements and simulated time. Each operation returns the `Outcome` the API should give:
success with a few fields (status, amounts), or the typed error code from
`docs/api-errors.md`.

It is written to be obviously right, not fast, and it is **independent of the code it
checks** wherever a shared helper could hide a bug:

- It books its own entries for each row of the money-flow table instead of calling
  `Ledger::Flows`. If a builder in `Flows` were wrong, a model that called it would agree.
- It computes fees with `Rational` and an explicit half-even rule instead of calling
  `FeeSchedule`, so a rounding bug in `FeeSchedule` shows up as a difference of one minor
  unit rather than being copied into the expectation.
- It keeps its own table of which accounts are debit-normal.

The money a step moves is also emitted as `Event`s (one per `Ledger::Flows` builder:
capture, settlement, funds_available, refund, and so on). A system under test that only
has a ledger, and no domain code yet, uses them to know what happened. See "Systems under
test".

### Policies encoded

From `docs/design/ledger.md`:

- Capture books gross to the processor receivable, net to merchant pending and our fee
  (2.9% + 30c by default, rounded half-even) to fee revenue.
- Settlement books cash net of the acquirer's fee (1.5% + 10 minor units) and clears the
  receivable for the gross.
- **Our fee is not returned on a refund.**
- **Refunds come out of available, not pending**, even if that takes available negative.
- **Disputes debit available for the amount plus the dispute fee**, may take it negative,
  and the negative balance is carried; the next captures pay it down when their funds
  become available.
- **The dispute fee is kept when the dispute is won**; the amount comes back.
- **Payouts are blocked while available is zero or negative**, and never exceed it.
  Pending and held funds are not available, so they are never paid out.
- Payout failure returns the money to available.

From `docs/design/sim.md` (the acquirer's behaviour the model has to predict):

- Declines by test token (`generic_decline`, `insufficient_funds`, `expired_card`).
  A decline puts the intent back to `requires_payment_method`.
- `pm_card_disputeFraudulent` opens a dispute for the **captured** amount 7 days after
  capture. Refunds made before it opens do not shrink it.
- **The acquirer refuses a refund (`charge_disputed`) once the dispute has opened on its
  side**, even if Clearinghouse has not processed the notification yet. Payments records
  the refund as `failed` and releases its reservation (`docs/design/payments.md`), so the
  API answers 200 with a failed refund and no money moves.
- A payout is paid one simulated day after it is sent, and fails if its amount in minor
  units ends in 13.
- Every movement settles `settlement_lag_days` (2) after the UTC date it happened, in the
  first file generated on or after that date, exactly once.
- One capture per authorization; a partial capture releases the rest.

From `docs/design/payments.md` (payments M2, which the model was aligned to when it
landed):

- **An amount smaller than our fee on it is refused** with `amount_too_small`, at create
  and at capture, so the merchant's share is never negative. At the default fee that is 31
  cents; in JPY and KWD, with no fixed part, any positive amount covers it.
- Illegal transitions are `payment_intent_unexpected_state`. A capture past the
  authorization and a refund past what is left are `parameter_invalid` on the amount; a
  refund of a fully refunded payment is `charge_already_refunded`.
- Declines are `card_declined` with the decline code, except an expired card, whose code
  is `expired_card`.
- **An authorization waits 7 days for capture**, then the expiry sweep cancels it. The
  model runs the sweep whenever the clock moves, as the API adapter does.

### Interpretations where the docs are silent

Each of these is a decision the model makes that another area might make differently.
When the real API is wired in and disagrees, one of the two changes, on purpose.

1. **Availability is by date, not by settlement.** Funds become available whether or not
   the settlement line has arrived. The payouts work has since decided the date: the start
   of the UTC day `payout_delay_days` (2) after the day of capture
   (`Balances::Availability.available_on`). The model first used capture time plus 48
   hours and now follows the documented rule.
2. **Dispute fee per currency.** $15.00 comes from the ledger doc. The model's first guess
   for other currencies (1500 JPY, 5.000 KWD) was wrong against `Disputes::FeePolicy`
   (2200 JPY, 4.600 KWD). The first API run with disputes wired shrank that to 6 steps: a
   KWD payment on the disputing card, then 7 days.
3. **Error codes** follow Stripe's names: `balance_insufficient` (payouts, as built),
   `dispute_not_open` and `dispute_already_closed` (the simulator's codes for resolving a
   dispute).
4. **`pm_card_timeout` succeeds.** The acquirer commits and drops the connection. The
   model expects the confirm to end as `pm_card_visa` does, which is where M3's
   ambiguous-call handling has to get it. Payments M2 answers 503 and leaves the intent in
   `processing`, so the API adapter leaves this card out for now.
5. **Notifications are delivered when the clock moves.** `advance_clock` moves time and
   then lets the notification worker deliver everything due, in due-time order: disputes
   opening, payouts paid or failed. `resolve_dispute` delivers `dispute.closed` at once.
6. **A second settlement run for the same date changes nothing**, since the acquirer
   returns the same frozen file and the reconciler dedupes by line.
7. **Held is always zero.** Nothing posts to `merchant:<id>:held` in the model. Risk
   holds (M6) are on main but their payout side is not; when it lands, the model needs a
   hold operation. The checks already compare the held account, so a posting to it that
   the model does not expect is caught.

The first version of the model had its own guesses where payments has since decided:
a minimum charge of 50 minor units, `amount_too_large` for over-captures and over-refunds,
`card_declined` for an expired card, and no authorization expiry. The first run against the
API disagreed on each of those, and each time the model was wrong, not the API, because
payments' choices are documented and deliberate. None of them was a bug.

## Systems under test

`Sut` is the adapter interface: one method per operation, each returning the `Outcome`
the system produced, plus `snapshot` (balances by account, open clearing flows, captured
and refunded per payment, and the system's own invariant violations) and `reset!`.
Objects are named by the sequence (`m1`, `pi_3`, `re_1`, `po_2`); an adapter maps those
names to its own ids and reports everything under the sequence's names.

The reference model implements `Sut` itself, so the harness can run the model against a
second copy of the model. That run must be clean, and it is the sanity check that the
generator, checks and shrinker work before any real system is involved.

### The ledger-level system under test

`LedgerSut` runs the money side of every operation through the real ledger on real
Postgres. It was built before any domain endpoint was on main, so the domain *decisions* (is this transition legal, did the card decline, which
settlement lines arrived today) come from a shadow copy of the model. What the adapter
does itself is what the domain code will do with the money:

- computes our fee with `FeeSchedule` and the acquirer's with the simulator's schedule,
  not with the model's arithmetic;
- posts the `Ledger::Flows` builder for each event with `Ledger.post!`, under the object's
  flow id and the simulated clock, one database transaction per operation;
- **decides payouts itself**, reading available with `Ledger.balance_for_update` inside the
  posting's transaction, which is the check the payouts code must make;
- snapshots balances from `account_balances` (the row `Ledger.balance` returns, read in one
  query rather than one per account, which made each step about ten times slower; a spec
  checks the two agree), open flows from `Ledger::Clearing.report`, captured and refunded
  per payment from the entries themselves, and violations from `Ledger::Invariants.check`
  plus the clearing report's orphan balances.

So a sequence tests the ledger, the flow builders, the fee code and the payout balance
rule against the model, including the flows whose domain code has not landed (disputes,
settlement, payouts). It does not test domain logic; the API adapter does.
Between sequences the ledger tables are emptied as the owner with triggers off for one
transaction, and only in a database whose name contains `test`.

### The API system under test

`ApiSut` sends every operation as an HTTP request through the real Rack app
(`Api::RequestLogger` around `Api::App`, via `Rack::Test`) with JSON bodies and the
merchant's secret key. The app talks to the real acquirer simulator on a Puma server on an
ephemeral port in the same process, over TCP. Outcomes come from the responses; the
snapshot reads the database the app wrote (balances, the clearing report, invariants, and
`amount_received` / `amount_refunded` from `payment_intents`), with API ids mapped back to
the sequence's names. Nothing is shadowed.

| operation | how | status |
|---|---|---|
| create_merchant | `POST /v1/merchants` with the admin token, `fee_percent`, `fee_fixed` | wired |
| create_intent | `POST /v1/payment_intents` | wired |
| confirm | `POST /v1/payment_intents/:id/confirm` | wired |
| capture | `POST /v1/payment_intents/:id/capture` (`amount_to_capture`) | wired |
| cancel | `POST /v1/payment_intents/:id/cancel` | wired |
| refund | `POST /v1/refunds` | wired |
| advance_clock | advance the test clock, run `Payments::Expiry.sweep!`, then one `NotificationPoller#poll` | wired |
| payout | `POST /v1/payouts` (`amount`, `currency`) | wired |
| availability_sweep | `Balances::Availability.release_due!` at the test clock | wired |
| resolve_dispute | simulator `POST /admin/disputes/:id/resolve` (the network's ruling) at the test clock, then one poll | wired |
| settle | `Reconciliation::Ingestor#ingest` for the test clock's UTC date | wired |

The clock-driven operations call the pieces `bin/scheduler` runs, in the scheduler's order
(expiry, then notifications), rather than a whole tick. The model gives each of them its own
operation, and a tick would also run automatic payouts and the missing-line check, which
the model doesn't have. A dispute the poller creates is named after its payment (`pi_3`'s is
`dp_3`), as the model names it. Only `pm_card_timeout` is still in
`unsupported_payment_methods` (interpretation 4): its confirm answers 503 and leaves the
payment `processing` until a retry resumes it, which one sequence step does not do.

## Checks after every step

In this order, and the first one that fails names the failure:

| check | what it asserts |
|---|---|
| `outcome` | same success or error, same code and decline code, same value for every field both report |
| `balances` | every account's balance equals the model's (non-zero ones listed) |
| `zero_sum` | in each currency, debit-normal minus credit-normal balances sum to zero |
| `refunds_within_captures` | for every payment, refunded never exceeds captured, as the system reports them |
| `completed_flows_cleared` | no flow the model's *domain state* calls finished (settled, paid, resolved) holds money in a clearing account; this uses the model's state, not its balances |
| `open_flows` | the flows with money in clearing, and the amount per clearing account, match the model's |
| `ledger_invariants` | the system's own checks: `Ledger::Invariants.check` (zero sum, balanced transactions, `account_balances` equals the sum of entries via `Ledger::Checker`) and `Ledger::Clearing.report` orphan balances |

An exception from the system under test is a failure too (`exception`).

## Generating sequences

`Generator#next_command` looks at the model's current state and picks a weighted command:
mostly legal operations on objects that exist (confirm a confirmable intent, capture one
waiting for capture, refund a succeeded one, resolve an open dispute, pay out a funded
balance), and a steady share of illegal ones (confirm an intent that is already done,
capture more than authorized, refund past what is left, pay out more than is available,
resolve a dispute that has not opened, name an object that does not exist, amounts below
the minimum). Amounts are often round (500, 1500, 10000), because that is where
half-even rounding of a fee is decided and where people actually charge.

The value generators are `prop_check`'s (`frequency`, `choose`, `one_of`, `fixed_hash`),
all driven by one seeded `Random`, so a seed reproduces a sequence exactly.

**Why not `prop_check`'s own runner and shrinking.** `prop_check` 1.0.2 has no stateful
testing (its README lists it as future work), and its array shrinking only shortens a
list from the end and shrinks elements in place. The command that matters in a failing
sequence is usually in the middle, after setup that must stay, so that shrinking stalls.
The spec anticipated this ("if it proves thin, write a small generator by hand").

## Shrinking

`Shrinker` takes the failing sequence and:

1. cuts everything after the failing step;
2. runs **delta debugging** (Zeller's ddmin) over the list: drop a chunk, keep the result if
   it still fails, halve the chunk size when nothing can go, down to single commands;
3. shrinks the remaining numbers (amounts, hours) toward small and round values, trying
   round candidates first, then halving, then single steps;
4. repeats until nothing changes or a budget of 5000 runs is spent.

Commands name objects symbolically (`pi_3`), so dropping the command that created an
object leaves later commands naming something that does not exist. Those fail with
`resource_missing` on both sides and the candidate is still runnable. A candidate counts
only if it fails **the same check** (and for an exception, the same class), so shrinking
cannot slide from one bug to another; `spec/model/shrinker_spec.rb` tests that.

The result is printed as a script:

```ruby
Clearinghouse::Testing::Model::Harness.replay(sut: :ledger, plant: nil) do |h|
  h.create_merchant(merchant: "m1", fee_rate_scaled: 290000, fee_fixed: {"usd" => 30})
  h.create_intent(intent: "pi_1", merchant: "m1", amount: 500, currency: "usd", capture_method: "automatic")
  h.confirm(intent: "pi_1", payment_method: "pm_card_visa")
end
```

Each `h.<operation>` runs the step on the model and the system, prints both outcomes and
raises `Harness::Failed` with the check's details at the failing step.

## Running it

```
bin/model-test --sut ledger --sequences 300 --max-length 80 --seed 1
bin/model-test --sut model                                   # the model against itself
bin/model-test --sut ledger --plant fee_rounding             # the planted-bug demo
```

It prints sequences run and operations executed, writes
`results/exp4-model/<run>.md` and `.json` (machine, Postgres version, command, and counts of
every operation outcome and every money event, so a run that never reached a path is
visible), and on a failure `<run>-repro.rb`. In CI, `spec/model/ledger_sut_spec.rb` runs 12
sequences of up to 40 steps with a fixed seed, plus the planted-bug checks.

## Results

The final runs, on 2026-09-24 at commit `2860114`: Apple M3 Pro, 12 cores, 18 GB, Postgres
16.15 in Docker, Ruby 3.3.12, database `clearinghouse_test_model`. Other experiments were
running on the machine, so the elapsed times are loose. The pass/fail results don't depend on
time.

| run | sequences | operations | result | elapsed |
|---|---:|---:|---|---:|
| `--sut ledger --sequences 300 --max-length 80 --seed 1` | 300 | 17,826 | every check passed after every step | 496 s |
| `--sut api --sequences 300 --max-length 80 --seed 1` | 300 | 17,826 | every check passed after every step | 1,662 s |
| `--sut api --sequences 300 --max-length 80 --seed 2` | 300 | 18,091 | every check passed after every step | 555 s |

Files: `results/exp4-model/{ledger-seed1,api-seed1,api-seed2}-n300-l80.{md,json}` (`sequences`,
`operations`, `passed`, `by_outcome`, `money_events`). The API runs went through every wired
operation. Seed 1 posted 1,631 captures, 1,254 refunds (561 settled), 97 disputes opened (21
won by the merchant, 23 debited), 180 payouts (82 paid, 20 failed) and 728 settlements. Seed 2
posted 1,612 captures, 113 disputes and 175 payouts. The only real bug the model has found is
the settlement one under Findings. It was fixed before these runs.

A first attempt at the two API runs failed at the first `advance_clock`, because
`clearinghouse_test_model` was missing the latest migrations (`acquirer_cursors`). That was the
test database, not the code. After `bin/migrate` they ran as above.

## Earlier runs

Measured on an Apple M3 Pro, Postgres 16.15 in Docker, Ruby 3.3.12, with other agents'
test suites running on the same machine (so the times are loose). The run files in
`results/exp4-model/` have the details.

| run | sequences | operations | result |
|---|---|---|---|
| `--sut model --sequences 300 --max-length 80 --seed 1` | 300 | 17,826 | every check passed |
| `--sut ledger --sequences 300 --max-length 80 --seed 1`, before the model followed payments' fee rule | 300 | 17,826 | every check passed, 260s |
| `--sut api --sequences 150 --max-length 60 --seed 1` | 150 | 6,714 | every check passed, 669s |
| `--sut ledger --sequences 300 --max-length 80 --seed 1`, after | 130 | 7,660 | **failed** on sequence 130: the settlement bug under Findings |
| `--sut api --sequences 40 --max-length 80 --seed 1`, every operation wired | 40 | 2,269 | every check passed, 26s (smoke run on a shared machine) |

The model and ledger runs execute the same sequences, since generation depends only on the
seed and the model. The first API run (150 sequences) left out payouts, disputes,
settlement and the availability sweep. The 40-sequence run with everything wired reached 20
payouts (10 paid and 1 failed by the time the sequences ended), 8 disputes opened and 4
resolved, 86 settlement postings and 82 refund settlements. Only `pm_card_timeout` is still
left out. Each run's `.md` lists how many times each operation reached each outcome. The
final ledger run above replaced the failing run's `ledger-seed1-n300-l80.{md,json}`. The
failing run's shrunk replay script is kept as `ledger-seed1-n300-l80-repro.rb`.

## Planted-bug demo (deliberate, not a real bug)

This is the spec's interview-defense item 10 done on purpose: break something, let the
harness shrink it, and debug from the shrunk case. The bugs live in
`lib/clearinghouse/testing/model/planted_bugs.rb` and are injected into `LedgerSut`; the
real classes are never modified.

**1. Fee rounding flipped to half-up** (`--plant fee_rounding`). `bin/model-test --sut
ledger --plant fee_rounding --sequences 50 --max-length 60 --seed 1` failed at step 47 of
the twelfth sequence, a confirm whose payment was one of several round amounts. The
shrinker took 68 runs to cut 47 steps to 3, and swapped the `pm_card_timeout` of the
original for a visa on the way:

```ruby
Clearinghouse::Testing::Model::Harness.replay(sut: :ledger, plant: :fee_rounding) do |h|
  h.create_merchant(merchant: "m1", fee_rate_scaled: 290000, fee_fixed: {"usd"=>30})
  h.create_intent(intent: "pi_6", merchant: "m1", amount: 500, currency: "usd", capture_method: "automatic")
  h.confirm(intent: "pi_6", payment_method: "pm_card_visa")
end
# step 3 failed check balances:
#   merchant:m1:pending (usd): model 456, system 455, off by -1
#   platform:fee_revenue (usd): model 44, system 45, off by 1
```

Debugging from there takes a minute: the fee on $5.00 is one cent high, 2.9% of 500 is
14.5, and the model's half-even says 14. The shrinker's amount pass tried the round
candidates below 500 first and none of them fails, which is itself the hint: 500 is the
smallest USD amount whose 2.9% ends in exactly .5.

**2. A flow that skips its clearing account** (`--plant payout_failed_skips_clearing`,
measured before the model followed payments' fee rule, which is why the payment below is
the old 50 minimum):
`payout_failed` returns the money to the merchant out of cash instead of out of
payout_clearing. It balances, so the database accepts it. The run failed in sequence 31 at
step 45 and shrank to 7 steps in 1465 runs (about 90 seconds, most of it Postgres round
trips):

```ruby
h.create_merchant(merchant: "m1", fee_rate_scaled: 290000, fee_fixed: {"usd"=>30})
h.create_intent(intent: "pi_2", merchant: "m1", amount: 50, currency: "jpy", capture_method: "automatic")
h.confirm(intent: "pi_2", payment_method: "pm_card_visa")
h.advance_clock(hours: 48)
h.availability_sweep
h.payout(payout: "po_5", merchant: "m1", currency: "jpy", amount: 13)
h.advance_clock(hours: 24)
# step 7 failed check balances:
#   platform:cash (jpy): model 0, system 13, off by 13
#   platform:payout_clearing (jpy): model 0, system 13, off by 13
```

Every step left is needed: a payment, time for its funds to become available, a payout
whose amount ends in 13 (the simulator's failure rule, which the shrinker found by trying
13 first), and the day for the bank to answer. The disputing card of the original
sequence was replaced by a visa, and the payment shrank to the 50 yen minimum. The
`open_flows` check would have caught it too (po_5 still holds 13 in clearing), but
`balances` comes first.

## Findings

**A capture smaller than its fee cannot be posted.** While payments was still being built,
an exploratory run with the model's minimum charge taken out (not committed) failed on
the third step of `create_intent(amount: 1)` then `confirm`: `Ledger::Flows.capture` builds
`merchant pending = gross - fee`, which is -29 cents, and `post!` refuses it with
`InvalidPostingError: entry amounts must be positive`. The ledger is right to refuse; the
guarantee has to come before the acquirer is asked to capture. Payments M2 landed with
exactly that guard (`Support.check_covers_fee!`, `amount_too_small`), and the model now
encodes it. Not logged in `docs/bugs`, since no merged code did the wrong thing.

**A payment whose fee equals its amount has a zero net, and `Flows.funds_available` does
not accept one.** `capture`, `settlement` and `dispute_opened` drop zero-amount lines, but
`funds_available` does not. Payments accepts a 31 cent USD charge at the default fee
(fee 31, so `fee <= amount` holds), posts the capture without a pending line, and calls
`Seams.schedule_availability` with a net of zero. When the payouts work fills that seam,
moving zero from pending to available will raise `InvalidPostingError` unless it skips
zero nets. The model makes no zero-net availability posting and the ledger adapter skips
it too, so once the API adapter runs the availability sweep, a sequence with a 31 cent
payment will check the real code on this. The generator produces amounts in 1..60 for
this reason.

**A payment smaller than the acquirer's fee could never be settled** (a real bug, in
`docs/bugs/model-settlement-fee-over-gross.md`). Once the model followed payments' fee rule,
the ledger run with seed 1 found that a 1 fils payment, which payments accepts, produces a
settlement line whose acquirer fee (10 fils) exceeds its amount, and `Flows.settlement`
built a negative cash debit that `post!` refused. It shrank from 56 steps to 5. Fixed in
`Flows.settlement`.

**Against the whole API (payouts, disputes and the reconciler wired), no system bug so
far.** The first run with every operation wired disagreed four times, and each time the
model was wrong, not the system. Each system behaviour is a documented decision:

| model's guess | the system, and where it is decided |
|---|---|
| dispute fee 1500 JPY, 5000 KWD | 2200 JPY, 4600 KWD (`Disputes::FeePolicy`) |
| available 48 hours after capture | at the start of the UTC day two days after the capture day (`docs/design/payouts.md`) |
| a new payout is `pending` | `in_transit` once the bank accepted it; `pending` is only a payout not yet sent (`docs/design/payouts.md`) |
| a refund after the dispute opened at the acquirer is an error, `charge_disputed` | a 200 with a `failed` refund, its reservation released (`docs/design/payments.md`) |

Only the first showed up as a shrunk failure: rerunning the old model against the wired
API with `--sequences 40 --max-length 80 --seed 1` stopped there. The other three were
found by reading the payouts and payments docs while wiring the adapter, and each is now
pinned by a spec in `spec/model/reference_model_spec.rb` and `spec/model/api_sut_spec.rb`.

**Against the real API (payments M2), no disagreement either.** Every difference the first
API run found was the model's guess against a documented payments decision (see
"Policies encoded").
