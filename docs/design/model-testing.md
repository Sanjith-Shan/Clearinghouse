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
