# Experiment 6: webhook delivery under hostile endpoints

**Status: measured on a quiet machine on 2026-09-25.** The published run is
`20260925T193937Z-quiet/`, below. Two earlier runs on a loaded machine are kept, labelled
with their load, as checks. The development trials further down used an older claim
implementation and are kept only because they drove a design change.

## Results

- Command: `bin/exp-webhooks --runs fifo,isolated,isolated-kills,isolated-cap4 --out
  results/exp6-webhooks/20260925T193937Z-quiet` (all four runs, the settings below), then
  `bundle exec ruby exp/webhooks/claim_bench.rb 32 375` into the same directory.
- Commit `2860114`. Apple M3 Pro, 12 cores, 18 GB, PostgreSQL 16.15 in Docker, Ruby 3.3.12.
- **Load:** nothing else heavy was running. The 1-minute load average was 9.5 at the start,
  left over from experiment 3's run just before, and 7.8 at the end. `summary.json` doesn't
  record load, so these readings come from the run log.
- Files: `20260925T193937Z-quiet/summary.json` (`runs[run=...]`: `ttd_s`, `ttd_by_window_s`,
  `missing`, `duplicates`, `duplicate_rate`, `worker_kills`), `table.md`, `claim_bench.json`.

| run | cap | kills | p50 s | p90 s | p99 s | max s | healthy received | duplicates | hung-endpoint requests | bad signatures |
|---|---|---|---|---|---|---|---|---|---|---|
| fifo | - | 0 | 41.413 | 119.715 | 139.138 | 140.158 | 5021/5021 | 0 (0.0%) | 1249 | 0 |
| isolated | 2 | 0 | 0.073 | 0.103 | 0.128 | 0.426 | 5021/5021 | 0 (0.0%) | 56 | 0 |
| isolated-kills | 2 | 15 | 0.074 | 0.102 | 0.119 | 15.123 | 5021/5021 | 4 (0.08%) | 64 | 0 |
| isolated-cap4 | 4 | 0 | 0.077 | 0.232 | 1.115 | 1.275 | 5021/5021 | 0 (0.0%) | 72 | 0 |

- **Head-of-line blocking:** under FIFO the healthy endpoints' median wait grew with every
  10 s window of event creation: 2.1 s, 8.3 s, 18.8 s, 54.6 s, 83.0 s, 125.6 s. Each retry of
  a hung delivery re-enters the queue ahead of newer work and holds a worker for the 5 s read
  timeout. With per-endpoint isolation the healthy p50 was 73 ms and p99 128 ms, flat across
  the run (every window between 68 and 79 ms at p50). Isolation made 56 requests to hung
  endpoints where FIFO made 1,249.
- **Workers killed:** 15 `kill -9`s during emission. Every committed event reached every
  healthy endpoint (missing 0), and 4 of 5,021 pairs arrived twice (0.08%). That fits the
  at-least-once cost of a worker dying after the endpoint answered and before the delivery
  was marked. The maxima of about 15.1 s, one in five of the six windows, match the 15 s
  lease, which fits a killed worker's claimed delivery waiting for its lease to expire. I
  didn't trace the individual deliveries.
- **Cap 4 against cap 2:** a higher per-endpoint cap lets more workers pile onto the hung
  endpoints before their breakers open. The first 20 s were worse (p99 up to 1.2 s), and after
  that there was little difference. Cap 2 stays the default.
- **Claim throughput** (`claim_bench.json`, 32 threads claiming and completing 1,500
  deliveries, no HTTP, one Postgres round trip measured at 0.2 ms): FIFO handed out 2,338
  deliveries a second and the isolated claim (one `webhook_claim_isolated` call) 2,497. At
  this size the bench runs for well under a second, so read that as "about the same", not as
  isolation being faster. The Ruby-driven isolated claim in the trials below managed 62 to 83
  a second on a loaded machine.

### Earlier runs on a loaded machine (checks, not quoted)

| directory | 1-minute load | fifo p50 / p99 s | isolated p50 / p99 s | isolated-kills duplicates | claim bench fifo / isolated per s |
|---|---|---|---|---|---|
| `20260924T231717Z-load10-100` | 10 at start, 100 by the end | 45.911 / 224.11 | 0.183 / 0.621 | 7 of 5,021 (0.139%), 14 kills | 134 / 836 (round trip 2.16 ms) |
| `20260925T070741Z-load14-40` | 14 at start, 25 to 40 later | 47.321 / 145.027 | 0.127 / 1.355 | 26 of 5,021 (0.518%), 15 kills | 454 / 484 (round trip 1.7 ms) |

Both had missing 0 in every run and no bad signatures. The load changed the isolated times
several-fold and the duplicate count, not the conclusion. The first loaded claim bench showed
the isolated claim far ahead of FIFO, while the second and the quiet one show them about
level. So that gap was noise from load, and I don't quote it.

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
`docs/design/webhooks.md`). Both were rerun for the results above.

