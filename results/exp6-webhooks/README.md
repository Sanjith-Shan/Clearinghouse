# Experiment 6: webhook delivery under hostile endpoints

**Status: the final runs have not been done yet.** They are to be run on a quiet machine
with the command below, which writes `summary.json` and `table.md` into this directory.
The numbers further down are from development trials on a loaded machine, two of them with
an older claim implementation, and are here only because they drove a design change.

## Question

With a hundred endpoints of which some return 500s, some hang past the timeout and one
flaps, how long do the *healthy* endpoints wait for their events under a single FIFO queue,
and under per-endpoint isolation (in-flight cap plus circuit breaker)? And with workers
`kill -9`ed at random during the isolation run, does every committed event still reach
every healthy endpoint, and how many arrive twice?

## Setup

- **Machine:** Apple M3 Pro, 12 cores, 18 GB. PostgreSQL 16.15 in Docker (docker compose
  `db` service), Ruby 3.3. `summary.json` records these again at run time, plus the
  measured Postgres version string.
- **Endpoints:** 100, on one hostile server process (`exp/webhooks/hostile_server.rb`),
  one port, one path per endpoint (`http://127.0.0.1:<port>/e/<n>`, allowed by the
  workers' `--test-mode`). Isolation is keyed on the endpoint id, so separate ports or
  hostnames would change nothing the queue sees. Kinds, shuffled with seed 6:
  - 83 healthy: 200 after 5 to 30 ms;
  - 8 error: 500 after 5 to 30 ms;
  - 8 hang: read the request, never answer, hold the connection 60 s;
  - 1 flapping: healthy and error in alternating 10 s periods.
- **Merchants:** 25, four endpoints each (endpoint n belongs to merchant n mod 25), every
  endpoint subscribed to `*`, so each event is delivered to four endpoints.
- **Events:** open loop at 25 events a second (100 deliveries a second) for 60 s, each
  for a random merchant, written straight into the outbox with `Events.emit!`.
- **Delivery:** one `bin/dispatcher` (0.05 s poll), 4 `bin/webhook-worker` processes of 8
  threads (32 workers), connect timeout 2 s, read timeout 5 s, total 10 s, lease 15 s.
  Isolated runs: in-flight cap 2 per endpoint (plus a run with 4), breaker opens after 5
  consecutive failures, 30 s first cool-down. Retries use the production policy (1 minute
  base, full jitter).
- **Runs:** `fifo`, `isolated`, `isolated-kills` (every 2 to 6 s a random worker process
  gets SIGKILL and a replacement starts at once, while events are being emitted), and
  `isolated-cap4`.
- **Drain:** after the last event, each run waits until the database shows every healthy
  delivery succeeded (at most 600 s), then stops everything.

Command:

```
bin/exp-webhooks                 # all four runs, the settings above
```

The database is `clearinghouse_exp_webhooks`, created if missing and emptied before each
run. Raw logs (the server log, worker and dispatcher output) go to
`results/raw/exp6-webhooks/`, which is not committed.

## What is measured, and how

- **Time to delivery** for each (healthy endpoint, event) pair: the wall time at which the
  hostile server finished writing its first 200 for that event, minus the event's
  `created_at`. The server's log is the ground truth; the database is only used for the
  event times and which endpoints each event was for. p50, p90, p99 and max are
  nearest-rank, and `summary.json` also has them per 10 s window of event creation, which
  shows the start-up transient while breakers are still closed.
- **Completeness:** every event in the outbox against every healthy endpoint of its
  merchant, checked in the server log. `bin/exp-webhooks` exits non-zero if any pair is
  missing.
- **Duplicates:** 200s beyond the first per healthy pair, from the server's log, as a
  count and as a share of pairs.
- **Signatures:** the server verifies every request's `Clearinghouse-Signature` against
  the endpoint's secret; failures are counted.
- **Wasted work:** requests to hung endpoints, per run.

### Simulated time and wall time

Every process in this experiment uses `Clock::Real`, so simulated time *is* wall time.
Network timeouts are always wall time (they are socket timeouts inside Net::HTTP), while
retry backoff, breaker cool-downs and leases are measured on the Clock. Running on the
wall clock keeps them on the same scale. A faster-than-wall test clock would shrink the
30 s cool-down and the 15 s lease relative to a 5 s read timeout, and a lease shorter than
a request is a lease that expires mid-delivery. So the experiment does not compress time,
and a consequence is that failing deliveries see only their first few retries (the
policy's first delays are up to 1, 2 and 4 minutes) rather than the three-day schedule,
which the specs cover with a test clock instead.

## Development trials (not the results)

Loaded machine: other agents' test suites were running against the same Postgres, and one
round trip to it measured about 3 ms. Settings as above except where noted. These used the
first, Ruby-driven isolated claim, which is no longer the code.

| trial | run | duration | p50 s | p90 s | p99 s | max s | healthy received | duplicates | hung-endpoint requests |
|---|---|---|---|---|---|---|---|---|---|
| 1 | fifo | 15 s | 5.204 | 7.114 | 9.421 | 9.59 | 1236/1236 | 0 | 149 |
| 1 | isolated | 15 s | 1.355 | 2.341 | 2.46 | 2.597 | 1236/1236 | 0 | 48 |
| 2 | fifo | 30 s | 14.295 | 40.424 | 53.002 | 53.235 | 2479/2479 | 0 | 467 |
| 2 | isolated | 30 s | 4.515 | 6.64 | 7.347 | 7.689 | 2479/2479 | 0 | 48 |

Head-of-line blocking shows plainly in FIFO, and grows with the run: in trial 2, FIFO's
median by 10 s window of event creation went 3.4 s, 14.3 s, 29.0 s, because every retry of
a hung delivery re-enters the queue ahead of newer healthy work (the FIFO queue orders by
event time) and holds a worker for 5 s. Isolation made 48 requests to hung endpoints
against FIFO's 467, and its breakers ended open on all 8 hung, all 8 error and the flapping
endpoint. No signature failed in any run.

But isolation's own times were not good: a median of 4.1 s in trial 2's last window, after
every breaker had opened. A control with every endpoint healthy (15 s, same settings)
showed why: isolated p50 3.582 s and p99 4.932 s against FIFO's 0.746 s and 3.567 s. The
isolated claim took five or six round trips where FIFO's takes one, and
`exp/webhooks/claim_bench.rb` (32 threads claiming and completing 1500 deliveries with
no HTTP) measured 62 and 83 claims a second for it against 245 and 386 for FIFO. The claim
now runs as one PL/pgSQL function call (`webhook_claim_isolated`, see
`docs/design/webhooks.md`). Neither the bench nor the experiment has been re-run since.

The kill -9 run has not been done yet, so there is no duplicate rate to report.
