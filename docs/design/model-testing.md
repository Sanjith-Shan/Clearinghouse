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
- **Refunds fail `charge_disputed` once the dispute has opened at the acquirer**, even if
  Clearinghouse has not processed the notification yet.
- A payout is paid one simulated day after it is sent, and fails if its amount in minor
  units ends in 13.
- Every movement settles `settlement_lag_days` (2) after the UTC date it happened, in the
  first file generated on or after that date, exactly once.
- One capture per authorization; a partial capture releases the rest.

### Interpretations where the docs are silent

Each of these is a decision the model makes that another area might make differently.
When the real API is wired in and disagrees, one of the two changes, on purpose.

1. **Availability is by date, not by settlement.** Funds become available
   `payout_delay_days` (2, the merchant default) after capture, like Stripe's
   `available_on`, whether or not the settlement line has arrived. The money-flow table
   lists "funds become available" after settlement but does not say it waits for it.
2. **Minimum charge.** `create_intent` and `capture` refuse amounts below 50 (USD, JPY) or
   200 (KWD) minor units with `amount_too_small`. Nothing in the docs sets one. Without
   one, a capture smaller than its fee has a negative net, and `Ledger::Flows.capture`
   would build a negative credit that `post!` rejects.
3. **Dispute fee per currency.** $15.00 comes from the ledger doc; 1500 JPY and 5.000 KWD
   are mine.
4. **Error codes** the docs do not list yet: `payment_intent_unexpected_state` for an
   illegal transition, `amount_too_large` (capture past the authorization, refund past
   what is left), `amount_too_small`, `charge_already_refunded`, `charge_disputed`,
   `balance_insufficient` (payouts). These follow Stripe's names.
5. **`pm_card_timeout` succeeds.** The acquirer commits and drops the connection; the
   payments flow resolves that through the acquirer's status query. The model expects
   the confirm to end exactly as `pm_card_visa` does. An API adapter must retry the confirm
   under the same idempotency key (or run the completer) until the intent leaves
   `processing`.
6. **Notifications are delivered when the clock moves.** `advance_clock` moves time and
   then lets the notification worker deliver everything due, in due-time order: disputes
   opening, payouts paid or failed. `resolve_dispute` delivers `dispute.closed` at once.
7. **A second settlement run for the same date changes nothing**, since the acquirer
   returns the same frozen file and the reconciler dedupes by line.
8. **Authorization expiry is not modelled.** The payments area owns its duration; add
   an `expire_authorizations` operation once it exists.
9. **Held is always zero.** Nothing posts to `merchant:<id>:held` until risk reviews
   (M6). The checks still compare it, so the first posting to it is covered.

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
Postgres. The domain endpoints (payments, refunds, disputes, payouts) are not on main yet,
so the domain *decisions* (is this transition legal, did the card decline, which
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

So today a sequence tests the ledger, the flow builders, the fee code and the payout
balance rule against the model. It does not test domain logic; the API adapter will.
Between sequences the ledger tables are emptied as the owner with triggers off for one
transaction, and only in a database whose name contains `test`.

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

## Results so far

Measured on an Apple M3 Pro, Postgres 16.15 in Docker, Ruby 3.3.12 (the run files in
`results/exp4-model/` have the details):

| run | sequences | operations | result |
|---|---|---|---|
| `--sut model --sequences 300 --max-length 80 --seed 1` | 300 | 17,826 | every check passed, 10.4s |
| `--sut ledger --sequences 300 --max-length 80 --seed 1` | 300 | 17,826 | every check passed, 260s |

The two runs execute the same sequences, since generation depends only on the seed and
the model. The ledger run posted every `Ledger::Flows` event, and its `.md` lists how
many times each operation reached each outcome, including the illegal ones.

## Planted-bug demo (deliberate, not a real bug)

This is the spec's interview-defense item 10 done on purpose: break something, let the
harness shrink it, and debug from the shrunk case. The bugs live in
`lib/clearinghouse/testing/model/planted_bugs.rb` and are injected into `LedgerSut`; the
real classes are never modified.

**1. Fee rounding flipped to half-up** (`--plant fee_rounding`). `bin/model-test --sut
ledger --plant fee_rounding --sequences 50 --max-length 60 --seed 1` failed at step 25 of
the third sequence, a JPY payment of 500 whose fee landed on exactly half a yen. The
shrinker took 51 runs to cut 25 steps to 3, and moved the currency to USD on the way:

```ruby
Clearinghouse::Testing::Model::Harness.replay(sut: :ledger, plant: :fee_rounding) do |h|
  h.create_merchant(merchant: "m1", fee_rate_scaled: 290000, fee_fixed: {"usd"=>30})
  h.create_intent(intent: "pi_3", merchant: "m1", amount: 500, currency: "usd", capture_method: "automatic")
  h.confirm(intent: "pi_3", payment_method: "pm_card_visa")
end
# step 3 failed check balances:
#   merchant:m1:pending (usd): model 456, system 455, off by -1
#   platform:fee_revenue (usd): model 44, system 45, off by 1
```

Debugging from there takes a minute: the fee on $5.00 is one cent high, 2.9% of 500 is
14.5, and the model's half-even says 14. The shrinker's amount pass tried the round
candidates below 500 first and none of them fails, which is itself the hint: 500 is the
smallest USD amount whose 2.9% ends in exactly .5.

**2. A flow that skips its clearing account** (`--plant payout_failed_skips_clearing`):
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

**A capture smaller than its fee cannot be posted.** With the minimum charge taken out of
the model (an exploratory run, not committed), the ledger adapter failed on the third step
of `create_intent(amount: 1)` then `confirm`: `Ledger::Flows.capture` builds
`merchant pending = gross - fee`, which is -29 cents, and `post!` refuses it with
`InvalidPostingError: entry amounts must be positive`. The ledger is right to refuse. The
gap is upstream: something has to guarantee `fee <= gross` before the acquirer is asked to
capture, because once it has, a failed posting leaves money moved with no ledger record. A
minimum charge amount does it for the default fee; a merchant fee schedule with a fixed part
above the minimum would still hit it. This is interpretation 2 above, and the payments area
should decide it. Not logged in `docs/bugs`, since no merged code does the wrong thing.

Related, from reading `Flows` while writing the adapter: `capture`, `settlement` and
`dispute_opened` drop zero-amount lines, but `funds_available` does not, so a payment whose
fee equals its gross (a 31 cent charge on the default fee) would make the availability
sweep fail on a zero entry. The adapter skips a zero net, and the real sweep will have to
as well.
