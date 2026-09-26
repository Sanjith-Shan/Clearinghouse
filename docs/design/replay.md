# Experiment 8: the replay through Clearinghouse and RiskGate

RiskGate's experiment 8 and Clearinghouse's M6 are the same run. RiskGate's test month is
replayed through Clearinghouse's API. Clearinghouse asks RiskGate about every confirm, and
the fraud-labelled payments come back as disputes. The run is repeated under three policies:

| Policy | What runs |
|---|---|
| `none` | Clearinghouse with the risk client off. RiskGate is not called |
| `model_only` | RiskGate with `rules/model_only.rules`: block when the calibrated fraud probability is at least 50% |
| `model_rules` | RiskGate with `rules/default.rules`: the same block threshold, plus a review band and rules |

Code: `bin/exp-replay`, `sim/experiments/replay.rb` and `sim/experiments/replay/`. Spec:
`spec/experiments/replay_spec.rb`. Results: `results/exp8-replay/`.

## What is real and what is simulated

**Real:** the transactions. The replay file is RiskGate's export of the IEEE-CIS test month
(`~/Documents/RiskGate/data/export_real/test_replay.jsonl`, 92,427 rows in time order): the
amount, the currency (all USD), the `risk_fields` RiskGate's model and rules read, the
timestamp, and the fraud label. RiskGate's model and rule sets are the real ones, chosen on
the validation month.

**Simulated:** everything around them.

- The acquirer is `sim/`. Every card approves. A fraud-labelled row pays with
  `pm_card_disputeFraudulent`, which opens a `fraudulent` dispute for the full captured
  amount 7 simulated days after capture. A legitimate row pays with `pm_card_visa`. So
  **every fraud payment that gets through is disputed, in full, a week later, and none is
  won.** Real chargebacks are not like that. Not every fraud is disputed, disputes arrive
  over weeks, and some are won.
- **The dispute fee is an assumption: 15.00 USD per dispute**, Stripe's published US fee.
  It is labelled as assumed in every report.
- A blocked legitimate payment counts as lost revenue at its full amount. The customer
  doesn't retry with another card, and the merchant's margin isn't modelled.
- A reviewed payment is captured and its funds are held. No human resolves the reviews, so
  the holds stay open to the end of the run.
- The clock is simulated. There is one merchant with the default fee schedule and daily
  automatic payouts.

**Kaggle rule.** The file is read in place and rows live only in the driver's memory.
Nothing from a row is written anywhere. Idempotency keys are built from the row's position,
not its `payment_id`, and the reports hold aggregates only. The spec's rows are
hand-written and come from no data file. The smoke runs use RiskGate's synthetic file.

## How a run works

`bin/exp-replay` runs everything in one process except RiskGate and Postgres: the API and
the acquirer simulator on Puma over real sockets, the scheduler, and the webhook dispatcher
and delivery workers. That is what lets the run use a test clock. The API and the simulator
share one `Clock::Test`, and the driver moves it.

For each row, in file order:

1. The clock moves to the row's `created`. With `--speed X`, the driver also waits until
   `(created - first created) / X` wall seconds into the run. The default is 0, as fast as
   the stack answers. The intent's `created_at` is what Clearinghouse sends RiskGate as
   `created`, so RiskGate's velocity features see the transaction's own time. The clock never goes
   back, so a row out of order would be created at the clock's current time. Rows like that
   are counted in the report. The export is in order, so the count should be 0.
2. `POST /v1/payment_intents` with `amount`, `currency` and `risk_fields` exactly as read.
   No key is added, because RiskGate rejects unknown keys.
3. `POST /v1/payment_intents/:id/confirm` with the row's test card and automatic capture,
   through `ClearinghouseClient` with an Idempotency-Key. The client's retries reuse the
   key. The call is timed from the client, and the risk step inside it is timed around
   `Risk::Client#assess`.
4. The outcome is one of `approved`, `review` (captured, payout held), `risk_unavailable`
   (captured unchecked: fail open), `unchecked` (policy `none`), `blocked` (402
   `risk_error` / `payment_blocked`: nothing posted, and the acquirer never hears of it),
   `declined` or `error`. The last two don't happen with these cards, and they are counted
   if they do.

At each new simulated day the scheduler ticks once (`docs/design/scheduler.md`). After the
last row, the clock moves one day at a time for `dispute_after_days + 1` days, with a tick
each day, so every dispute from the last captures has opened.

### Disputes

The scheduler's notification step (`Acquirer::NotificationPoller` with
`Settlement.notification_handlers`) reads the simulator's feed at every tick and opens a
Clearinghouse dispute for each `dispute.opened`. The dispute is posted to the ledger and
emitted as `charge.dispute.created`. After the last tick, the driver counts
`GET /v1/disputes` (`disputes_source` in the report). It also counts the disputes the
simulator itself opened on this run's payments (`disputes_in_simulator`), so the two can
be checked against each other. They should match.

The poller keeps its cursor on the feed in the database, but each run's simulator is new
and numbers its feed from the start. A cursor left by an earlier run would skip this
run's disputes, so the driver refuses a database that holds one. Run with `--reset-db`.

### Labels back to RiskGate

For `model_only` and `model_rules`, the driver registers a webhook endpoint at
`<riskgate-url>/v1/webhooks/clearinghouse` for `payment_intent.succeeded`,
`charge.dispute.created` and `charge.dispute.closed`. Those are the events RiskGate's label
store reads. RiskGate reads its signing secrets from `RISKGATE_WEBHOOK_SECRETS` once, at
start, and Clearinghouse generates an endpoint's secret. So the driver writes a known secret
(`--webhook-secret`, default `whsec_exp8_replay_not_a_secret`) onto the endpoint's row after
registering it. The app role may, since roll_secret does the same. This is for the
experiment only.

The delivery workers sign with the wall clock, because RiskGate checks timestamps against
its own wall clock. Test-mode `SafeHttp` allows the `http://127.0.0.1` URL. At the end the
driver waits up to 120 s for the endpoint's deliveries to drain. The report says whether
the workers ran, whether the deliveries drained, and the deliveries by event type and status.

## The report

`results/exp8-replay/<timestamp>/<policy>.json` and `<policy>.md`. All money is in USD.
The JSON keeps cents.

| Field | Meaning |
|---|---|
| payments, approved | rows, and those that went through (approved + review + risk_unavailable + unchecked) with their volume |
| blocked, reviews, risk_unavailable | counts and volume |
| fraud caught | blocked rows labelled fraud |
| legitimate revenue blocked | blocked rows labelled legitimate |
| disputes | count and volume, from `disputes_source` |
| dispute losses | disputed volume + 15.00 USD assumed fee per dispute |
| net | saved minus cost, below |
| latency | confirm p50/p99/p99.9 as the client saw it, the risk step's p50/p99, and the risk step's share of confirm time |
| holds | review holds opened, the captured amount under review, the merchant net held |
| webhooks | registered, workers ran, drained, deliveries by type and status |
| provenance | command, machine, load average before and after, RiskGate URL and deployed ruleset version (and the versions seen on decisions), row count, seed, simulated time span |

**Net.** `saved` is what blocking fraud avoided. Each blocked fraud payment would otherwise
have been captured and disputed for its full amount plus the assumed fee. `cost` is the
legitimate revenue blocked. `net = saved - cost`. Reviews change neither. A reviewed fraud
payment is still captured and still disputed, and the hold only keeps the money on the
platform until the dispute comes. That is the same accounting RiskGate used to choose its
block threshold (`rules/model_only.rules`). In this simulation every fraud payment that gets
through is disputed, so across runs
`net(policy) = dispute losses(none) - dispute losses(policy) - legitimate revenue blocked(policy)`,
which checks the three runs against each other.

## The full runs

Run on 2026-09-25. The results are under "Results" below. The procedure, agreed with the
RiskGate session:

- **Each policy starts from its own copy of a warm snapshot.** RiskGate replays all
  498,113 pre-test payments, in `(TransactionDT, TransactionID)` order, into
  `~/Documents/RiskGate/var/exp8_warm/`, so its velocity features see the history before
  the test month, as they would in production. Wait until the RiskGate session says it is
  ready. Every run copies it (`cp -R`) and never shares a state directory, since a
  policy's payments would otherwise count in the next one's features.
- RiskGate runs with `-snapshot-interval 0 -decision-log off` and without `-table`, on
  `127.0.0.1:8091` (port 8080 was taken on this machine on 2026-09-24). Never use
  DBGuard's ports.
- The snapshot restores `rules/default.rules` as version 1. `bin/exp-replay` PUTs the
  policy's rule file to `/v1/rules` before the first row anyway. For `model_only` that PUT
  is what switches the rules, and the run stops if it fails.
- `/v1/assess` refuses a `created` more than 24 hours past the latest event it has
  accepted (`-max-future-skew`). The replay is in time order and starts where the warm
  history ends, so this should never fire. If it does, those confirms show up as
  `risk_unavailable` with reason `http_status`, and the run should be treated as broken.
- **Reset Clearinghouse's database for every run** (`--reset-db`).

```sh
export PATH=/opt/homebrew/opt/ruby@3.3/bin:$PATH
cd ~/Documents/Clearinghouse                        # main, with this branch merged
DB=clearinghouse_test_loadgen                       # an existing database; --reset-db empties it
REPLAY=~/Documents/RiskGate/data/export_real/test_replay.jsonl
SECRET=whsec_exp8_replay_not_a_secret
OUT=results/exp8-replay/$(date -u +%Y%m%dT%H%M%SZ)-full
SCRATCH=~/Documents/Clearinghouse-wt/_coord/exp8   # RiskGate's run state, not in any repo
HEAVY=~/Documents/Clearinghouse-wt/_coord/heavy.sh
(cd ~/Documents/RiskGate && go build -o "$SCRATCH/riskgate" ./cmd/riskgate)

riskgate() {  # a RiskGate for one policy, on its own copy of the warm snapshot
  cp -R ~/Documents/RiskGate/var/exp8_warm "$SCRATCH/run-$1-state"
  (cd ~/Documents/RiskGate && RISKGATE_WEBHOOK_SECRETS=$SECRET exec "$SCRATCH/riskgate" -addr 127.0.0.1:8091 \
     -snapshot-dir "$SCRATCH/run-$1-state" -snapshot-interval 0 -decision-log off \
     -model models/ieee -rules rules/default.rules -lists rules/lists.json) &
  RG=$!
  until curl -fs http://127.0.0.1:8091/healthz >/dev/null; do sleep 1; done
}

# 1. No checks. RiskGate isn't involved.
$HEAVY bin/exp-replay --replay "$REPLAY" --policy none --label full --db $DB --reset-db --out "$OUT"

# 2. The model threshold alone (the driver PUTs rules/model_only.rules).
riskgate model_only
$HEAVY bin/exp-replay --replay "$REPLAY" --policy model_only --riskgate-url http://127.0.0.1:8091 \
  --webhook-secret $SECRET --label full --db $DB --reset-db --out "$OUT"
kill $RG; wait $RG

# 3. Model plus rules (the driver PUTs rules/default.rules).
riskgate model_rules
$HEAVY bin/exp-replay --replay "$REPLAY" --policy model_rules --riskgate-url http://127.0.0.1:8091 \
  --webhook-secret $SECRET --label full --db $DB --reset-db --out "$OUT"
kill $RG; wait $RG
```

The binary is built once so that `kill` stops RiskGate itself rather than `go run`.

**How long.** The 50-row smoke went at 22.4 rows a second under `none` and 25.7 under
`model_rules`, on a machine with a load average of about 10. An earlier 200-row smoke at a
load of 18 to 25 went at 13 to 23 rows a second. At those rates a full policy takes 1 to 2
hours. The full runs went at 4.3 to 4.5 rows a second (about 6 hours each), with three
running concurrently, a missing index slowing the reaper, and a system sleep partway through
(see Results). The rows go one at a time because RiskGate's velocity features depend on
order.

**The deadline.** Confirm gives RiskGate 50 ms (`--deadline-ms`). On a loaded machine some
calls will miss it and go through as `risk_unavailable`. The report counts them, and they
belong in the write-up: that is the fail-open cost, not noise to rerun away.

## Results

The three policies over all 92,427 payments of the test month, run concurrently on
2026-09-25, each with its own database, RiskGate process, port and fresh copy of the warm
snapshot, at Clearinghouse `2860114` and RiskGate `016337a`. `model_sha256`
`a75d7ac4071e27f8f72bcf91c0fa6f2c8e0ecaf5ba032aad0e9e30df919ce540` was checked before each model run.
Full tables, the load, the mid-run index fix and the stall are in
`results/exp8-replay/README.md`.

| | none | model_only | model_rules |
|---|---:|---:|---:|
| Blocked | 0 | 384 ($100,221.48) | 384 ($100,221.48) |
| Fraud caught | 0 | 227 ($59,862.04) | 227 ($59,862.04) |
| Legitimate revenue blocked | 0 | 157 ($40,359.44) | 157 ($40,359.44) |
| Disputes | 3,213 ($487,462.76) | 2,986 ($427,600.72) | 2,986 ($427,600.72) |
| Dispute losses (assumed $15.00 fee) | $535,657.76 | $472,390.72 | $472,390.72 |
| Review holds | 0 | 0 | 2,496 ($413,409.07 held) |
| Net against none | $0.00 | +$22,907.60 | +$22,907.60 |
| Unchecked (deadline missed) | - | 24 | 8 |

The model's block cut 227 of 3,213 fraud payments (7.1%, 12.3% of fraud dollars) and blocked
157 legitimate ones (0.18% of legitimate payments), for a net of +$22,907.60 on the assumed
fee. The review rules change no money here, because a review lets the payment through and
holds the payout. What they add is 2,496 holds on $413,409.07 of merchant funds, of which the
replay never resolves any. Whether the holds pay for themselves depends on what an analyst
would decide, which this experiment doesn't model. All ledger invariants held, and the
disputes seen through the API matched the simulator's count exactly in every run.

The runs were slower than planned, at about 4.4 rows a second. Two things contributed: a
missing index behind the reaper (fixed mid-run, speed only, logged in `docs/bugs/`) and a
system sleep in the middle, which also put a roughly 4,492 s stall in every run's confirm
latency tail. The latency figures are not quotable.

## Smoke

`results/exp8-replay/20260924T200001Z-smoke/`: the first 50 rows of RiskGate's
**synthetic** file under `none` and `model_rules`, against the fake RiskGate with
`sim/experiments/replay/fake_policy.json`, whose rules are made up for the smoke (block at
400.00 USD and up, review at 200.00 USD and up). It checks that the pieces connect. Under
`model_rules`, 1 payment was blocked, 2 review holds opened, and both fraud rows that got
through were disputed through the poller. `GET /v1/disputes` matched the simulator
(2 disputes, $28.17). 49 `payment_intent.succeeded` and 2 `charge.dispute.created`
webhooks were delivered and drained, with no scheduler errors and no ledger invariant
violations. Its money and latency say nothing about RiskGate and are not publishable.

## What the spec proves

`spec/experiments/replay_spec.rb` runs five hand-written rows through the whole stack against
the fake RiskGate under `model_rules` and `none`:

- A block posts nothing: no ledger transaction, no authorization at the simulator, and the
  intent is back in `requires_payment_method` with `payment_blocked`.
- A review holds funds: the hold is open for the captured amount, and after the replayed
  week of availability sweeps the merchant's net is in held.
- A fraud row that gets through produces exactly one dispute, and nothing else does.
- The arithmetic: approved, blocked, fraud caught, legitimate revenue blocked, dispute
  losses with the assumed fee, and net, to the cent. Under `none`, every fraud row is
  disputed and net is zero.
- RiskGate gets each row's own `created` and its `risk_fields` unchanged, and the labels
  arrive over signed webhooks.

The fake RiskGate gained `POST /v1/webhooks/clearinghouse` for this. It verifies
`Clearinghouse-Signature` against the wall clock as RiskGate does and dedupes by event id.
`spec/risk/fake_riskgate_spec.rb` checks it with signatures from Clearinghouse's own signer.

## Not done here

- Experiment 9 end to end (kill RiskGate during this replay) reuses this driver but isn't
  built. It needs a way to kill and restart RiskGate mid-run, as `bin/exp-risk-failure`
  has.
- Reviews are never resolved, and no refunds are modelled.
