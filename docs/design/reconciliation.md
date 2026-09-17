# Settlement and reconciliation

Code: `lib/clearinghouse/reconciliation/`, `lib/clearinghouse/api/routes/reconciliation_exceptions.rb`.
Schema: `db/migrations/20260926120000_settlement_reconciliation.rb`.

Our ledger says what should have happened to money. The acquirer's daily settlement file
says what did. The reconciler compares the two, line by line, and every line either
**clears** its flow (we post the settlement transaction and the flow's clearing account goes
back to zero) or becomes a **reconciliation exception** with a typed reason that an
operator resolves. The idea comes from the clearing accounts in Ilya Ganelin's *Ledger*
post (reading list 3): money parks in a clearing account until an outside record confirms
it, so anything the outside record does not confirm stays visible as a non-zero balance.

## The file

`Acquirer::Client#settlement_file(date:)` returns the CSV for a date
(`line_id, type, acquirer_reference, operation_id, amount, fee, currency, settled_on`,
format in `docs/design/sim.md`). `Reconciliation::Ingestor#ingest(date)` fetches it and, in
**one database transaction**, stores the raw bytes with their SHA-256 in `settlement_files`,
one row per CSV line in `settlement_lines`, every settlement posting, and every exception.
Either all of a file is reconciled or none of it is.

- **Idempotent.** `settlement_files.settled_on` is unique. Ingesting a date again finds the
  row, checks the hash, and returns `already_ingested` without touching anything (the spec
  compares every row of five tables before and after). The acquirer freezes files once
  generated, so a different hash for a date we already have raises `FileChangedError`
  rather than trust either copy.
- **Strict parsing.** Every field is an id, an integer, a currency code, a type name or the
  file's own date, so a split on commas is an exact parser. A file with a row that does not
  fit (wrong header, a non-integer amount, an unknown type or currency, a line dated for
  another day) is refused whole. A reconciler that skipped the rows it could not read would
  report a clean day.
- **Serialized.** Ingestion takes a transaction-scoped advisory lock, and so does the SLA
  job, so a line being cleared is never declared missing by a job that cannot see the
  uncommitted posting yet.

## Matching a line to a flow

The expectation always comes from our books, never from the line:

| line type | flow | expected amount | expected fee | clears |
|---|---|---|---|---|
| `capture` | the payment with that `acquirer_reference` (`PaymentLookup`) | the capture's debit to processor_receivable | the acquirer's contract: 1.5% + 10 minor units, half-even | processor_receivable |
| `refund` | the refund with that acquirer `operation_id` | minus the refund's credit to refund_clearing | 0 | refund_clearing |
| `dispute` | the dispute with that acquirer dispute id | minus the disputed amount | 0 | dispute_clearing |
| `dispute_reversal` | the same dispute, once it is won | the disputed amount | 0 | dispute_clearing |

The acquirer's fee schedule is configuration (`Reconciliation::Config`), not something we
read off the file: a fee we accepted because the file said so could never be found wrong.

A line that matches exactly posts the named flow from `Ledger::Flows` (`settlement`,
`refund_settled`, `dispute_debited`, `dispute_funds_returned`), dated at the file's date,
with a description that names the payment (`settlement of pi_...`, `acquirer debit for
dispute dp_... on pi_...`) so `bin/explain` links it.

## The reasons a line does not clear

| reason | how it is found | what is posted | what it leaves in clearing |
|---|---|---|---|
| `duplicate` | a line with the same `acquirer_reference`, line type and `operation_id` as one we already have (in this file or any earlier one) | nothing | nothing |
| `amount_mismatch` | the line's amount differs from what our ledger moved into clearing | the cash that really moved | the difference |
| `fee_mismatch` | the amount matches and the fee differs from the contract | the cash that really moved; processing_expense at the contract fee | the difference (the acquirer owes it) |
| `late` | the line should have been in an earlier file we already ingested (below) | the normal settlement, once | nothing; recorded and resolved on arrival |
| `unknown_payment` | the capture's acquirer reference, or the refund's operation id, matches nothing of ours | nothing | nothing |
| `missing` | no line has come for a movement we expect, a day past its due date (the SLA job, below) | nothing | the whole expected amount |

**Duplicates are by identity, not amount.** Two partial refunds of one payment for the same
amount are different movements (different operation ids) and both clear. A repeated line
is one movement however its amount reads. The first copy is booked and every later copy
is flagged and never booked.

**Mismatches book the cash that moved.** The alternative, refusing to post a line that
disagrees, leaves cash out of the ledger that is really in the bank. So a mismatched line
books `amount - fee` to cash and the contract fee to processing_expense, and the flow's
clearing account takes the rest. For a line that matches, that is exactly the named flow.
For one that does not, the difference stays in clearing, the flow stays unexplained, and the
exception's `unexplained_amount` says how much (signed on the clearing account's normal
side). The data-quality report finds it without being told there was a problem.

A line gets at most one of `amount_mismatch` and `fee_mismatch`, amount first, because a
wrong amount usually drags the fee with it. Lateness is judged separately, so a line that is
both late and wrong gets both exceptions. Experiment 5's random injections can hit a
deferred line again in the file it moves to, which is how this came up.

### What "late" means, and the carried-over line that is not late

A line is late if an earlier file we ingested should have held it. The simulator's rule is
that a movement goes in the first file *generated* on or after its due date
(`happened + settlement_lag_days`), provided it happened before that file was generated. So
the reconciler calls a line late only if there is an earlier ingested file that:

1. is dated on or after the line's due date,
2. was requested at a simulated time at or after the movement (`requested_at >= happened_at`),
3. was fetched after we recorded the movement (`fetched_at > ledger_transactions.created_at`).

Condition 3 is the subtle one. A caller with a lagging test clock can capture "two days
ago" after today's file was already built. The simulator carries that line into the next
file and lists it in the manifest as `carried_over` with `injected_late: false`. By
simulated times alone it looks late (its due date's file exists and is dated after it). By
the order things really happened it was never in that file's reach. Simulated time cannot
order those two events, because two clocks are involved, so the reconciler orders them with
the database's clock: `settlement_files.fetched_at` is `clock_timestamp()` taken **before**
the request, and a ledger posting's `created_at` is set by the same server. If our posting
was created before the fetch began, the acquirer had the movement when it built the file.
The spec builds exactly this case and checks it clears without an exception.

Each condition can only make the reconciler say "not late" when in doubt, which is the
direction that keeps false exceptions at zero. The cost is that a late line whose flow we
recorded late ourselves (the poller was behind) is not reported late. It still clears.

A late line clears when it arrives, exactly once, and gets a `late` exception that is
resolved on creation (`resolution_action: auto`). It is a record, not a task.

### Lines ahead of our books

A `dispute` or `dispute_reversal` line can arrive before the poller has handled the
notification that tells us about the dispute (or the win). If the payment it names is ours,
the line is `pending`: nothing is posted, no exception is raised, and
`Ingestor#match_pending` tries it again at the end of every ingestion (and can be called
after the poller catches up). A dispute line for a payment we do not know is an
`unknown_payment` straight away.

## Missing lines and the data-quality job

A missing line is in no file, so no line can report it. `Reconciliation::MissingDetector`
works from our side instead: every movement our books expect the acquirer to settle, which
is each payment's capture, each refund, each dispute's opening and each won dispute's return,
and whether a line for it has arrived. A movement that happened on day H is due in the file
for H + `lag_days`; it is **missing** once we have ingested a file dated `slack_days` past
that and seen no line for it. Two choices in that sentence:

- **Measured in files, not hours.** If the reconciler did not run for three days, nothing
  becomes missing; the next files are fetched and the lines arrive. Staleness of the
  reconciler itself is a different alert.
- **One file of slack.** A line the acquirer sends one day late is then reported `late` when
  it arrives, instead of `missing` the day before and then resolved. With the simulator's
  default of one day for `late`, a late line never passes through `missing` at all.

The detector ages each expected line from its own movement, so a dispute won three months
after it opened is expected in the file two days after the win, not three months late.

When a line that was reported missing does arrive, the ingestor closes the open `missing`
exception itself with a note. If an operator had already written it off, the write-off is
reversed in the same transaction as the late line's settlement, because the money did arrive
and booking both would count it twice. There is a unique index on `(flow_id, line_type)` for
`missing`, so the detector can run as often as the scheduler likes.

`bin/data-quality` runs the detector and then reports, per the spec's "clearing checks and
explainability":

- **Explainability** per flow type and currency: the share of volume in flows whose clearing
  accounts are back at zero (`Ledger::Clearing.report`).
- **Flows open past their SLA**, with the amount stuck in each clearing account and how long
  it has been there. SLAs (`DataQuality.default_slas`): payments and refunds lag plus slack
  (3 days), payouts 1 day plus slack, disputes 120 days. The clearing report ages a flow from
  its first transaction, and a dispute's clearing account is legitimately open between a
  win and the returned funds, however long after the opening that is, so a shorter dispute
  SLA would flag healthy disputes. Dispute lines that really are overdue are caught by the
  detector, which does not have that problem.
- **Orphan clearing balances**: a stored clearing balance no open flow accounts for.
- The reconciler's open exceptions by reason, and lines still waiting for their flow.

It exits 1 when anything needs attention, so a scheduler can alert on the exit status, and
takes `--as-of` because ledger time is simulated.

```
bin/data-quality --as-of 2026-03-06T00:00:00Z
bin/data-quality --no-raise --json
```

## Exceptions as an API resource

Exceptions are the platform's books, not a merchant's, so the routes take the admin token
(`CLEARINGHOUSE_ADMIN_TOKEN`), not a secret key:

```
GET  /v1/reconciliation_exceptions?status=open&reason=amount_mismatch&flow=pi_...&limit=&starting_after=
GET  /v1/reconciliation_exceptions/rex_...
POST /v1/reconciliation_exceptions/rex_.../resolve   note=... action=none|write_off|reverse ledger_transaction=...
```

The object carries the reason, the flow, the line as the acquirer sent it, what our ledger
expected, the clearing account and `unexplained_amount`, a `detail` sentence, and the
resolution once there is one. Resolving always takes a note. The optional posting is in the
exception's own flow, so `bin/explain` shows it with the rest of the flow:

- `none`: close with the note (a duplicate we never booked, an unknown payment handed to
  someone else).
- `write_off`: posts the unexplained amount out of the clearing account against
  processing_expense. A short payment by the acquirer becomes a loss and an overpayment a
  gain, and the flow is explained again.
- `reverse`: reverses one ledger transaction of the flow (`Ledger.reverse!`), for a posting
  that should not have been made.

An exception resolves once (`reconciliation_exception_resolved`), and a resolution that
cannot apply (nothing stuck to write off, a transaction from another flow) is
`resolution_invalid`.

## What it needs from payments

- `PaymentLookup.by_acquirer_reference` reads `payment_intents.acquirer_reference`.
- `PaymentLookup.refund_by_acquirer_operation` reads `refunds.acquirer_operation_id`, a column
  this work adds. The refund path (`Payments::Refunds.mark_succeeded`) stores the acquirer's
  operation id from the approved outcome. Two refunds of one payment share an acquirer
  reference, so this id is the only thing in the file that tells them apart.

## Experiment 5: a month with injected discrepancies

`bin/exp-reconciliation` (code in `lib/clearinghouse/experiments/`) runs a simulated month
and scores the reconciler against the simulator's ground truth. Results and the exact
commands are in `results/exp5-reconciliation/`.

**Setup.** The acquirer simulator and the API run in the experiment's process, each on a
real port, sharing one test clock. Three merchants sell in USD, JPY and KWD. N payments are
drawn up front from the seed (day, time, merchant, amount, card), so the traffic does not
depend on anything the system under test does: most cards approve, 2% decline, 3% are
`pm_card_disputeFraudulent`. 15% of payments get a refund one to five days later, half of
them full. Every dispute gets a ruling two to four days after it opens (won or lost at even
odds), and a quarter are accepted by the merchant first. Every third day one payment is made
with a clock two days behind, after that day's file was built, which makes the simulator
carry its line into the next file: a line that settles after its due date with nothing
wrong, the case the reconciler must not flag.

**Everything goes through the API.** Payments (create, confirm), refunds, payouts and
dispute accepts use the Ruby client library against the running API, and the operator
resolves exceptions through `POST /v1/reconciliation_exceptions/:id/resolve`. The lagging
payments go through a second API instance whose clock runs two days behind, sharing the
database and the simulator. Funds become available through the payouts work's availability
job, and payout notifications are applied by `Payouts.handle_notification` on the same
poller as disputes. The runner depends on a `Driver` interface, so another way in (the load
generator, a Go client) would be another implementation.

**Each day:** at 00:30 the poller runs, the day's file is fetched and reconciled, pending
lines are retried and the SLA job runs; at 01:00 the availability job runs and every
merchant with a positive available balance is paid out; then the day's traffic in time
order. K discrepancies of all six types are injected with the simulator's
`{random: n, seed}` into the files of days 3 to 30 (the first two have nothing due). A quiet
tail of 14 days lets disputes opened late in the month (seven days after capture), their
rulings and the last lines finish.

**Scoring** (`ReconciliationMonth::Scorer`). An injected discrepancy is detected when an
exception of the same type names the same movement (acquirer reference, line type, and
operation id where the exception has one). An exception that matches nothing injected is a
false exception. Explainability is `Ledger::Clearing.report` at the end of the tail, before
and after resolving every open exception (write-off where money is stuck, a note
otherwise).

Random injection can hit the same line twice, because a deferred line is fair game again
in the file it moves to. Three consequences for scoring, each found by running the small
month in `spec/experiments/reconciliation_month_spec.rb` until it failed:

- A line deferred twice arrives once and is reported late once; that one exception covers
  both `late` injections.
- A line late by more than the slack is called `missing` by the SLA job first, and that
  exception closes itself when the line arrives. It is counted as `missing_then_arrived`, not
  as false. This is the reconciler doing what it should: on the day the line was overdue, it
  was missing.
- A line deferred and then dropped by `missing` never arrives, so nobody could ever see that
  it was late. That `late` is counted as `not_observable` rather than as a miss.

Ids are random (`SecureRandom`), so the acquirer references differ between runs and the
seeded injection picks different lines each time: two runs with one seed have the same
traffic plan and the same injection draws, but not the same lines.
