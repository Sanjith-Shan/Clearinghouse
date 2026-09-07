# bin/explain: money movement you can read

`bin/explain <id>` prints the whole money trail of one flow. It exists for the question
an on-call engineer or a support person actually asks: "where is the money for this
payment right now, and why?" It is the per-flow view of the clearing checks in
Stripe's Ledger post (reading list item 3,
https://stripe.dev/blog/ledger-stripe-system-for-tracking-and-validating-money-movement):
`Ledger::Clearing.report` finds flows that did not clear across the whole ledger, and this
tool shows one of them entry by entry.

```
bin/explain pi_... | re_... | dp_... | po_... | <transaction id>
            [--json] [--db NAME] [--as-of 2026-01-06T00:00:00Z] [--[no-]color]
```

## What it prints

The payment from `spec/explain/explain_cli_spec.rb`: captured, settled, made available,
then partly refunded and disputed.

```
pi_1 · payment · merchant acct_rocket · 3 transactions

┌─────┬─────────────────────┬──────────────────────────────────┬────────────┬────────────┬──────────────────────┐
│ txn │ effective (UTC)     │ transaction / account            │      debit │     credit │ processor_receivable │
├─────┼─────────────────────┼──────────────────────────────────┼────────────┼────────────┼──────────────────────┤
│ #1  │ 2026-01-01 00:00:00 │ capture                          │            │            │           100.00 USD │
│     │                     │   platform:processor_receivable  │ 100.00 USD │            │                      │
│     │                     │   merchant:acct_rocket:pending   │            │  96.80 USD │                      │
│     │                     │   platform:fee_revenue           │            │   3.20 USD │                      │
├─────┼─────────────────────┼──────────────────────────────────┼────────────┼────────────┼──────────────────────┤
│ #2  │ 2026-01-03 00:00:00 │ settlement                       │            │            │             0.00 USD │
│     │                     │   platform:cash                  │  98.40 USD │            │                      │
│     │                     │   platform:processing_expense    │   1.60 USD │            │                      │
│     │                     │   platform:processor_receivable  │            │ 100.00 USD │                      │
├─────┼─────────────────────┼──────────────────────────────────┼────────────┼────────────┼──────────────────────┤
│ #3  │ 2026-01-03 00:00:00 │ funds available                  │            │            │             0.00 USD │
│     │                     │   merchant:acct_rocket:pending   │  96.80 USD │            │                      │
│     │                     │   merchant:acct_rocket:available │            │  96.80 USD │                      │
└─────┴─────────────────────┴──────────────────────────────────┴────────────┴────────────┴──────────────────────┘

Related flows
  re_1  refund   names pi_1     EXPLAINED
  dp_1  dispute  names pi_1     OPEN

EXPLAINED  every clearing account this flow touched is back at zero (platform:processor_receivable)
```

- **The header** gives the flow id, type, the merchant (read from the `merchant:<id>:...`
  account codes the flow posted to) and the number of transactions.
- **The table** is `Ledger::ExplainPrinter`'s: one block per transaction in effective
  order, its entries in debit and credit columns rendered with `Money#to_s`, and one column
  per clearing account the flow touched, showing that account's running net after each
  transaction. You can watch the $100 enter `processor_receivable` at capture and leave it
  at settlement.
- **Related flows** are other flows linked to this one (below). Each has its own status, so
  a payment that cleared but has an open dispute says so.
- **The last line** is `EXPLAINED` when every clearing account the flow touched is back at
  zero, or `OPEN` with what is stuck, where, and for how long.

A payment whose settlement was booked for $99.00 instead of $100.00:

```
pi_2 · payment · merchant acct_rocket · 2 transactions

┌─────┬─────────────────────┬─────────────────────────────────┬────────────┬───────────┬──────────────────────┐
│ txn │ effective (UTC)     │ transaction / account           │      debit │    credit │ processor_receivable │
├─────┼─────────────────────┼─────────────────────────────────┼────────────┼───────────┼──────────────────────┤
│ #1  │ 2026-01-01 00:00:00 │ capture                         │            │           │           100.00 USD │
│     │                     │   platform:processor_receivable │ 100.00 USD │           │                      │
│     │                     │   merchant:acct_rocket:pending  │            │ 96.80 USD │                      │
│     │                     │   platform:fee_revenue          │            │  3.20 USD │                      │
├─────┼─────────────────────┼─────────────────────────────────┼────────────┼───────────┼──────────────────────┤
│ #2  │ 2026-01-03 00:00:00 │ settlement                      │            │           │             1.00 USD │
│     │                     │   platform:cash                 │  97.40 USD │           │                      │
│     │                     │   platform:processing_expense   │   1.60 USD │           │                      │
│     │                     │   platform:processor_receivable │            │ 99.00 USD │                      │
└─────┴─────────────────────┴─────────────────────────────────┴────────────┴───────────┴──────────────────────┘

Related flows: none found (matched by flow id in descriptions)

OPEN  1.00 USD in platform:processor_receivable · open 5d 4h (since 2026-01-01 00:00 UTC, as of 2026-01-06 04:30 UTC)
```

"Open for" is measured from the flow's first transaction to `--as-of` (default: now),
the same age `Ledger::Clearing.report` compares with SLAs, so the two tools never disagree
about how late a flow is. Ledger times are simulated, so `--as-of` matters: pass the
simulated "now" to get an age that means something.

A refund shows the payment it belongs to:

```
re_1 · refund · merchant acct_rocket · 2 transactions

┌─────┬─────────────────────┬──────────────────────────────────┬───────────┬───────────┬─────────────────┐
│ txn │ effective (UTC)     │ transaction / account            │     debit │    credit │ refund_clearing │
├─────┼─────────────────────┼──────────────────────────────────┼───────────┼───────────┼─────────────────┤
│ #4  │ 2026-01-04 00:00:00 │ refund re_1 of pi_1              │           │           │       40.00 USD │
│     │                     │   merchant:acct_rocket:available │ 40.00 USD │           │                 │
│     │                     │   platform:refund_clearing       │           │ 40.00 USD │                 │
├─────┼─────────────────────┼──────────────────────────────────┼───────────┼───────────┼─────────────────┤
│ #5  │ 2026-01-06 00:00:00 │ refund settled re_1 of pi_1      │           │           │        0.00 USD │
│     │                     │   platform:refund_clearing       │ 40.00 USD │           │                 │
│     │                     │   platform:cash                  │           │ 40.00 USD │                 │
└─────┴─────────────────────┴──────────────────────────────────┴───────────┴───────────┴─────────────────┘

Related flows
  pi_1  payment  named by re_1  EXPLAINED

EXPLAINED  every clearing account this flow touched is back at zero (platform:refund_clearing)
```

Given a ledger transaction id (`42` or `#42`) it explains the flow that transaction
belongs to and says which transaction was asked for.

On a terminal the output is colored: flow id bold, green for zero clearing balances and
`EXPLAINED`, red for money sitting in clearing and `OPEN`. `--no-color` or `NO_COLOR`
turns it off, `--color` forces it on for a pipe, and output to a pipe is plain by default.
A spec checks that stripping the escape codes from the colored output gives exactly the
plain output, so color never changes alignment.

## JSON

`--json` prints the same trace for scripts: `status` (`explained` or `open`),
`open_seconds`, `stuck` (per clearing account), every transaction with its entries and its
`clearing_after`, and `related`. Amounts are integers in minor units with a `display`
string beside them, so nothing downstream parses money out of text. The payment above is
in `spec/fixtures/explain/payment_with_related.json`.

Exit status: 0 when the trace printed (open or not; read the status to decide), 1 when the
id has no ledger transactions, 2 for a bad command line.

## Related flows, and the gap

The ledger has no column that links a refund or dispute to its payment. Transactions
carry `flow_id`, `flow_type` and a free-text `description`, and nothing else points across
flows. Adding a `parent_flow_id` would be the proper fix, but it is a schema change to the
ledger, which is not this tool's to make.

So related flows come from a **convention**: a refund or dispute transaction's description
names the flow ids it relates to, for example `refund re_... of pi_...` or
`dispute dp_... opened on pi_...`. `bin/explain` searches both ways:

- flows whose descriptions name this flow (`names pi_1`: the refunds and disputes of a
  payment), and
- flows this flow's own descriptions name (`named by re_1`: the payment a refund belongs to).

Ids are matched as whole tokens, so `pi_1` does not match a description naming `pi_10`, and
an id named in a description that was never posted is skipped. The search is a scan of
`ledger_transactions.description` (`strpos`, no index), fine for an operator's tool and
wrong for a hot path.

What this means in practice:

- It only finds what the domain code writes. The convention is recorded in
  `docs/design/interfaces.md` so the refunds and disputes work follows it. A flow posted
  without it shows "Related flows: none found", which is accurate, not a guess.
- A description is not a constraint. Nothing stops a typo. If links start to matter beyond
  this tool (for example, "explainability of a payment including its refunds"), they
  should become a real column with a foreign key.

## Tests

`spec/explain/explain_cli_spec.rb` posts flows with `Ledger::Flows` in a `:db` spec and
compares the text and JSON output byte for byte with golden files in
`spec/fixtures/explain/`. Regenerate them with
`UPDATE_GOLDEN=1 bundle exec rspec spec/explain` and read the diff. It also covers transaction
ids, a flow stuck in two currencies, a flow with no clearing accounts, the `pi_1`/`pi_10`
token match, color, exit codes, and one run of the real `bin/explain` script as a subprocess
with `--db`.

`ExplainPrinter` gained one public method, `render_table`, which is the table part of
`render` pulled out unchanged, so this tool can write its own header and verdict. The
ledger's own printer spec still passes as it was.
