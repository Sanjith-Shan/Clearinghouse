# Internal interfaces

The contracts the parts of Clearinghouse are built against. Change one only in a PR that
updates every side of it.

## Ledger (`lib/clearinghouse/ledger/`)

```ruby
Ledger::Entry = T::Struct(account: String, side: :debit | :credit, amount: Money)   # amount > 0

Ledger.post!(db, flow_type:, flow_id:, description:, effective_at:, entries:) -> transaction id
  # Runs inside the caller's DB transaction if one is open (it must be, for atomic phases),
  # otherwise opens its own. Validates debits == credits per currency before writing, then
  # the deferred constraint trigger checks again at commit. Creates missing accounts from
  # the code (see below). Updates account_balances in the same transaction.
Ledger.reverse!(db, transaction_id, reason:, effective_at:) -> transaction id
Ledger.balance(db, account, currency) -> Money       # signed on the account's normal side
Ledger.balance_for_update(db, account, currency) -> Money   # SELECT ... FOR UPDATE on account_balances
Ledger::Checker.run(db) -> drift report (account_balances vs sum of entries)
Ledger::Clearing.report(db, as_of:, slas:) -> open flows past SLA, orphan clearing balances,
                                              explainability by flow type
Ledger.explain(db, flow_id) -> every transaction and entry for a flow, plus clearing state
```

As built (M1). Everything above holds; these are the details it left open:

- `Entry.debit(code, money)` and `Entry.credit(code, money)` build entries.
- `post!` raises before writing anything: `UnbalancedError` (`#imbalances` is
  `{currency => debits - credits}`), `InvalidPostingError` (non-positive amount, unknown
  side, fewer than 2 entries, empty flow id or type), `UnknownAccountError`, and
  `FlowTypeMismatchError`. **Every transaction of a flow has one `flow_type`**, one of
  `Ledger::Flows::PAYMENT | REFUND | DISPUTE | PAYOUT`, and the database enforces it.
- `reverse!` raises `TransactionNotFoundError`, `AlreadyReversedError` or
  `NotReversibleError` (a reversal can't be reversed; post the original again instead).
- `balance_for_update` must run inside a database transaction and creates the account if
  it doesn't exist, so there is always a row to lock.
- `Checker.run(db) -> Checker::Report(accounts_checked, drifts: [Drift(code, currency, stored, computed)])`.
- `Clearing.report(db, as_of:, slas: {flow_type => seconds})` returns `Clearing::Report`
  with `open_flows`, `past_sla`, `orphan_balances`, `explainability` (per flow type and
  currency) and `flow_types_without_sla`. `healthy?` means nothing is past SLA and there are no orphans.
- `Ledger.explain` returns `Explain::Explanation` (`steps`, `clearing`, `explained?`) and
  raises `Explain::FlowNotFoundError`. `ExplainPrinter.render(explanation, color: false)`
  gives the terminal table for `bin/explain`.
- `Invariants.check(db) -> [Violation]` and `Invariants.check!(db)` are for model-based
  tests.
- `Ledger::Flows.<event>(...)` returns the entries for each row of the money-flow table in
  `docs/design/ledger.md` (`capture`, `settlement`, `funds_available`, `refund`,
  `refund_settled`, `dispute_opened`, `dispute_debited`, `dispute_won`,
  `dispute_funds_returned`, `payout`, `payout_paid`, `payout_failed`). Domain code should post
  these rather than hand-writing entries.

### Account codes

Accounts are named by a code and a currency. Platform accounts:

| code | kind | normal side |
|---|---|---|
| `platform:cash` | asset | debit |
| `platform:processor_receivable` | clearing | debit |
| `platform:refund_clearing` | clearing | credit |
| `platform:dispute_clearing` | clearing | credit |
| `platform:payout_clearing` | clearing | credit |
| `platform:fee_revenue` | revenue | credit |
| `platform:dispute_fee_revenue` | revenue | credit |
| `platform:processing_expense` | expense | debit |
| `platform:dispute_losses` | expense | debit |

Merchant accounts, one set per merchant per currency:

| code | kind | normal side |
|---|---|---|
| `merchant:<merchant_id>:pending` | liability | credit |
| `merchant:<merchant_id>:available` | liability | credit |
| `merchant:<merchant_id>:held` | liability | credit |

A flow is **explained** when every clearing account it touched nets to zero within that
flow's transactions. Flow ids are the API object ids: `pi_...` for a payment (capture,
settlement, availability), `re_...` refunds, `dp_...` disputes, `po_...` payouts.

**Description convention for related flows.** The ledger has no column linking flows, so a
refund or dispute transaction's `description` names the payment it belongs to by id, e.g.
`refund re_... of pi_...`, `dispute dp_... opened on pi_...`. `bin/explain` finds related
flows by this convention (docs/design/explain.md).

## Acquirer simulator (`sim/`, its own process)

Base URL `CLEARINGHOUSE_ACQUIRER_URL`, default `http://127.0.0.1:4600`. JSON in and out.
Every request carries `Sim-Time: <ISO 8601>`, the caller's clock, so the simulator lives
in simulated time. Mutating requests carry `Idempotency-Key`. The simulator is seeded and
deterministic, keeps state in memory behind a mutex, and treats a repeated key as a replay.

| Method and path | Body | Response |
|---|---|---|
| `POST /authorize` | `payment_method, amount, currency, capture (bool), reference` | `operation` |
| `POST /capture` | `acquirer_reference, amount, currency (optional, checked)` | `operation` |
| `POST /void` | `acquirer_reference` | `operation` |
| `POST /refund` | `acquirer_reference, amount, currency (optional, checked)` | `operation` |
| `POST /payouts` | `reference, merchant_id, amount, currency` | `operation` |
| `GET /operations/:idempotency_key` | | `operation`, or 404 `{"error":"not_found"}` |
| `GET /notifications?after=<cursor>` | | `{"data":[notification], "next_cursor":...}` |
| `POST /settlement_files` | `date (YYYY-MM-DD), inject: [discrepancy]` | `text/csv`, frozen once generated |
| `GET /settlement_files/:date` | | the same `text/csv`, or 404 |
| `GET /admin/settlement_files/:date/manifest` | | ground truth: injected discrepancies and carried-over lines |
| `POST /admin/config` | `seed, latency_ms {p50,p99}, error_rate, drop_after_commit_rate, settlement_lag_days, dispute_after_days, fee {rate_scaled, fixed}` | config (`GET` reads it) |
| `GET /admin/operations?reference=` | | every operation, authorization, dispute and payout, plus `charges_by_reference` (captured > 1 is a double charge) |
| `POST /admin/disputes/:id/resolve` | `outcome: won or lost` | notification |
| `POST /admin/reset` | | |

Failure semantics the client depends on: `503` is decided before anything is committed
(definitely not processed); a dropped connection happens only after a commit (maybe
processed). A replay carries `Idempotent-Replayed: true`. A reused key with a different
body is `409 {"error":"idempotency_key_mismatch"}`. Malformed requests are `400` and do not
use up the key. Business-rule refusals (capture over the authorized amount, refund past
captured, anything after a void) are recorded operations with status `failed` and a
`decline_code`. An unmatched route is `404 {"error":"no_route"}`, distinct from the
status query's `not_found`. See `docs/design/sim.md`.

`operation` is `{id: "op_...", type, status: "approved" | "declined" | "succeeded" | "failed",
decline_code, acquirer_reference: "acq_...", amount, currency, idempotency_key, created_at}`.

Test tokens: `pm_card_visa`, `pm_card_mastercard` approve. `pm_card_chargeDeclined`
declines `generic_decline`, `pm_card_insufficientFunds` declines `insufficient_funds`,
`pm_card_expired` declines `expired_card`. `pm_card_disputeFraudulent` approves and opens a
`fraudulent` dispute `dispute_after_days` after capture. `pm_card_timeout` commits the
authorization and then closes the connection without a response. `drop_after_commit_rate`
does the same to a random share of any card's requests.

Notifications, visible once `Sim-Time` reaches their due time, each
`{id: "ntf_...", type, created_at (the due time), cursor, data}`:
`dispute.opened {dispute_id, acquirer_reference, amount, currency, reason}`,
`dispute.closed {dispute_id, outcome, acquirer_reference, amount, currency}`,
`payout.paid {reference, acquirer_reference}`, `payout.failed {reference, acquirer_reference, failure_code}`.
`dispute_after_days` defaults to 7. A payout is paid one simulated day after it is sent,
or fails `account_closed` if its amount in minor units ends in 13. Refunds on a charge
whose dispute has opened fail `charge_disputed`. `GET /notifications` takes `after` and
`limit` (default 100) and needs `Sim-Time`; follow `next_cursor`.

Settlement CSV columns: `line_id, type (capture | refund | dispute | dispute_reversal),
acquirer_reference, operation_id, amount, fee, currency, settled_on`. A capture settles
`settlement_lag_days` (default 2) after it happened. `amount` is gross and `fee` is the
acquirer's processing fee (default 1.5% + 10 minor units, rounded half-even), so cash
received is `amount - fee`. Refund and dispute lines are negative with fee 0, dispute
reversals positive with fee 0. `settled_on` is the file's date (a late line carries the
later date). Every movement appears in exactly one file unless `missing` dropped it.
Discrepancy types for `inject`: `missing`, `duplicate`,
`amount_mismatch`, `fee_mismatch`, `late`, `unknown_payment`. An item is either explicit,
`{type, acquirer_reference, line_type?, delta?, days?}` (`unknown_payment` takes
`amount?, currency?` instead of a target), or `{random: N, seed?, types?}`.

## Events and webhooks

Envelope, agreed with RiskGate:
`{id: "evt_...", object: "event", type, created (simulated unix seconds), api_version, data: {object}}`.
Types include `payment_intent.succeeded`, `payment_intent.payment_failed`,
`payment_intent.canceled`, `charge.refunded`, `charge.dispute.created`,
`charge.dispute.closed`, `payout.paid`, `payout.failed`.
Events are written to the `events` table in the same transaction as the state change.

Signature header `Clearinghouse-Signature: t=<unix>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>`,
two `v1` values during a secret rotation. Verifiers reject `|now - t| > tolerance` in either
direction. Shared vectors live in `spec/fixtures/signatures.json` in RiskGate's shape:
`[{name, secrets, payload, header, now, tolerance, valid, error}]`, error one of
`no_matching_signature`, `timestamp_outside_tolerance`, `malformed_header`, or null.

## RiskGate

`POST {RISKGATE_URL}/v1/assess` with `{payment_id, created, amount, currency, risk_fields}`,
headers `RiskGate-Deadline-Ms` and `Idempotency-Key: <payment_id>:<attempt>`. Response
`{assessment_id, decision: allow | block | review, risk_score, matched_rule, reasons, ruleset_version}`.
Non-200 or timeout is `risk_unavailable` and the payment proceeds (fail open).

As built (M6, `lib/clearinghouse/risk/`):

```ruby
Risk::Client#assess(AssessRequest, attempt:) -> Assessment | Unavailable(reason:, detail:, status:)
  # reason: timeout | breaker_open | http_status | malformed | connection. Never raises for
  # anything RiskGate or the network does. RISKGATE_URL (default http://127.0.0.1:8080),
  # RISKGATE_DEADLINE_MS (default 50). One per process: Risk.client.
Risk::Decision.apply(result) -> Verdict(action: Proceed | Block, risk: Hash, hold:, error:)
Risk::Step.call(intent_attrs, attempt:, clock:) -> Outcome(verdict, result, elapsed_ms, assessed_at)
  # intent_attrs: {id:, amount:, currency:, created_at:, risk_fields:}. Runs outside any
  # DB transaction, between intent_locked and authorization_requested.
Risk::Step.hold_on_capture!(db, risk:, merchant_id:, payment_intent_id:, amount_captured:, clock:)
  # Inside the capture transaction. Opens a hold through Risk.holds when risk is review.
Risk::Holds#open_hold!(db, merchant_id:, payment_intent_id:, amount:, reason:, clock:)
  # amount: what was captured. reason: RiskGate's reasons, or "risk_review". The API wires
  # Api::Dependencies#risk_holds = Risk::Holds::Delegate.new(Balances::Holds), which forwards
  # as Balances::Holds.open_hold!(db, flow_id: payment_intent_id, ...).
```

- `created` is the intent's `created_at` in unix seconds, so a retry under the same key sends
  the same body (RiskGate answers 422 to a reused key with a different body).
- `risk_fields` is passed through verbatim. RiskGate rejects unknown keys with 400.
- `ruleset_version` arrives as a number from RiskGate and is stored as a string.
- The intent's `risk` column is `{decision, score, reasons, assessment_id, ruleset_version}`
  or `{decision: "risk_unavailable", reason}`.
- The integration steps for confirm are in `risk-integration.md`, "Where the step sits in confirm".

## Balances and payouts (`lib/clearinghouse/balances/`)

See `docs/design/payouts.md`.

```ruby
Balances::Availability.available_on_for(db, merchant_id:, captured_at:) -> Time   # start of UTC day + payout_delay_days
Balances::Availability.schedule!(db, flow_id:, merchant_id:, net:, available_on:, clock:) -> Scheduled | nil
  # Called by Payments::Seams.schedule_availability inside the capture transaction. Idempotent on flow_id;
  # ConflictError on different terms.
  # nil (nothing scheduled) for a zero net.
Balances::Availability.release_due!(db, clock:) -> ReleaseReport   # the sweep; safe to run concurrently
```

Payouts (`lib/clearinghouse/payouts.rb`):

```ruby
Payouts.create!(db, merchant_id:, currency:, bank:, clock:, amount: nil) -> Payout   # reserve! then drive!
Payouts.reserve! / request_bank! / call_bank / record_bank!    # the atomic phases, in RECOVERY_POINTS order
Payouts.drive!(db, payout_id, bank:, clock:) -> Payout         # runs the phases left, from payouts.recovery_point
Payouts.resume_incomplete!(db, bank:, clock:)                  # finishes stopped payouts; the only finisher for automatic ones
Payouts::Flows::CREATE / CANCEL                                # flows payout.create (RECOVERY_POINTS) and payout.cancel, run by the API
Payouts.handle_notification(db, notification, clock:) -> :applied | :duplicate | :unknown_payout | :ignored
  # for payout.paid / payout.failed; the notification poller calls it; idempotent
Payouts.run_scheduled!(db, bank:, clock:) -> [Payout]          # daily sweep, after Availability.release_due!
```

Events go through `Balances::EventSink` (`emit!(db, merchant_id:, type:, object:, clock:)`), inside the
state change's transaction. The default writes to the outbox with `Events.emit!`, and `Balances::EVENT_TYPES`
lists them (all in `Events::TYPES`).

Risk-review holds (`lib/clearinghouse/balances/holds.rb`):

```ruby
Balances::Holds.open_hold!(db, flow_id:, merchant_id:, amount:, reason:, clock:) -> Hold   # RiskGate said review
Balances::Holds.close_hold!(db, id, merchant_id:, decision: :approve | :reject, clock:) -> Hold
Balances::Holds.release_after_refund!(db, flow_id:, clock:)   # Refunds.mark_succeeded calls it with Flows.refund
Balances::RefundRequester#request_refund!(db, payment_intent_id:, reason:, clock:) -> refund id
Balances::PaymentsRefundRequester.new(ctx)   # Payments::Refunds.reserve! inside the reject's first phase
Balances::ReviewFlows::REJECT                # flow review.reject; its later phases are the refund's (refund_phases)
```
## Notifications and disputes (`lib/clearinghouse/acquirer/notification_poller.rb`, `lib/clearinghouse/disputes/`)

```ruby
NotificationPoller::Handlers#register(type) { |db, notification| ... }   # runs inside the poller's transaction
Settlement.notification_handlers(clock:) -> Handlers                        # what bin/poller runs with
PaymentLookup.by_acquirer_reference(db, acquirer_reference) -> Payment(id, merchant_id, currency) | nil
Disputes::Service#opened / #closed(db, notification), #accept(db, merchant_id:, id:, request: nil)
```

Payouts registers `payout.paid` and `payout.failed` on the same `Handlers`. A handler must
not commit; its effects commit with the notification's `processed_notifications` row and the
cursor. Dispute object: `{id: "dp_...", object: "dispute", payment_intent, amount, currency,
reason, status: needs_response | won | lost, fee, created, livemode}`. See
`docs/design/disputes.md`.

## Reconciliation (`lib/clearinghouse/reconciliation/`)

```ruby
PaymentLookup.refund_by_acquirer_operation(db, operation_id) -> Refund(id, payment_intent, merchant_id, currency) | nil
Reconciliation::Ingestor#ingest(date) -> Result(status, outcomes, exceptions, pending_matched)
Reconciliation::Ingestor#match_pending -> Integer
Reconciliation::Exceptions.resolve!(db, id, action: none | write_off | reverse, note:, clock:, ledger_transaction: nil)
```

`refunds.acquirer_operation_id` (set when the acquirer approves the refund) is how a refund's
settlement line finds it. Exception
reasons: `missing`, `duplicate`, `amount_mismatch`, `fee_mismatch`, `late`, `unknown_payment`.
See `docs/design/reconciliation.md`.
