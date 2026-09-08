# The load generator

`sim/loadgen` is an open-loop HTTP load generator written in Go, with `bin/loadtest` as
the wrapper that builds and runs it. It exists for experiment 8 (plain throughput and
latency of `confirm`), and its scenario engine is a library the retry storm or a replay
driver can reuse.

It is in Go, not Ruby, so the generator does not compete with the server for a Ruby VM
and its own pauses stay small next to the latencies it measures.

## Coordinated omission, in plain language

Gil Tene named this in his talk *How NOT to Measure Latency* (Strange Loop 2015, also
recorded at QCon: https://www.infoq.com/presentations/latency-response-time/), and his
`wrk2` (https://github.com/giltene/wrk2) and HdrHistogram (http://hdrhistogram.org) are
the tools built to avoid it.

Most simple load tools are closed loop: a client sends a request, waits for the answer,
then sends the next. Suppose the server freezes for one second. A closed-loop client
sends one request, waits a second, and records one slow sample. During that second it
sends nothing, so the hundreds of requests real users would have sent in that second,
all of which would have waited, are never sent and never recorded. The tool has
coordinated with the server: it backs off exactly when the server is bad, and so its
percentiles describe a server that was mostly fine. In the test below, at 200 requests
a second, about 200 requests were due during a one-second freeze. A closed-loop client
records one slow sample; about 200 users would have waited.

The fix is to decide in advance when each request should be sent, from the target rate,
and to measure each request's latency from that intended time, not from when it
actually went out. If the request could not be sent on time because the server (or the
generator's connection cap) was stuck, the time it spent waiting to be sent is part of
its latency, because a real user would have waited that long too.

`TestStallShowsUpInResponseTimeButNotServiceTime` shows this directly. A test server
stalls once for one second; the generator sends 200/s with one request allowed in flight.
One run on my laptop:

| ms | p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|---|
| service time (from actual send) | 0.245 | 1.881 | 6.543 | 1002.495 | 1002.495 |
| response time (from intended send) | 44.671 | 830.463 | 987.135 | 1003.007 | 1003.007 |

Service time, which is what a closed-loop tool would report, says p99 is 6.5ms. Response
time says one request in ten waited over 800ms, which is what happened.

## How it works

- **Schedule.** `Constant` puts request *i* at exactly *i*/rate seconds, computed from
  *i* rather than by adding a rounded period, so there is no drift over long runs.
  `Poisson` draws exponential gaps with mean 1/rate from a seeded source, so bursts
  happen the way independent clients cause them and a run can be repeated exactly.
- **Dispatcher.** One goroutine walks the schedule and puts each request on a queue at
  its intended time. It never waits on a response: that is the open loop. It sleeps
  until one millisecond before the intended time and then spins (see below).
- **Workers.** `-max-outstanding` workers take requests off the queue, each with its own
  connection (the HTTP client's pool is sized to match). This is a hard cap on requests
  in flight. When all workers are busy, due requests wait in the queue with their
  intended times attached, and are counted **late** when they go out more than
  `-late-threshold` after their intended time.
- **Drain and drops.** After the schedule ends, queued and in-flight requests get
  `-drain` (default the client timeout plus one second) to finish. Requests still
  queued then are **dropped**: counted as errors of class `dropped`, and recorded in
  the response-time histogram at a lower bound (drop time minus intended time), because
  leaving them out would let a server that stops answering look fast. Requests in flight
  at the deadline are canceled and recorded as `canceled`. Nothing is skipped silently:
  planned always equals completed plus dropped.
- **Three histograms,** in HdrHistogram at 1us to 10min, three significant figures:
  *response time* from the intended send, *service time* from the actual send, and
  *send delay*, the difference. Response time is the number to quote. Service time is
  there so the gap is visible. Send delay says whether the queueing was in the
  generator.
- **Errors** are classified: `http_NNN` for an unexpected status, `timeout`,
  `connection`, `canceled`, `dropped`, `capture_missing`, `no_prepared_state`. The
  summary also groups them (`http_4xx`, `http_5xx`). Failed requests stay in the
  histograms, and the error rate is reported next to the percentiles.

### Why the dispatcher spins

The first smoke run at 50/s showed a median send delay of about a millisecond. A Go
timer on an idle process wakes up late, and since latency is measured from the intended
time, that lateness was added to every sample. The dispatcher now sleeps until
`-spin` (default 1ms) before each send and busy-waits the rest; the median send delay
at 50/s dropped to about 0.01ms. At rates above 1000/s the gaps are shorter than the
window, so the dispatcher spins continuously and uses one core. `-spin 0` turns it off.
The summary records the setting. This is logged in `docs/bugs/loadgen-late-timer.md`.

## Scenarios

A scenario is a list of HTTP steps. Path, body and header values are Go `text/template`s
over the iteration's variables: the run's (`-key`, `-var name=value`), built-ins
(`{{.run}}` is random per run, `{{.iter}}` the iteration number), and values captured
from earlier responses by a dotted JSON path. A step fails on an unexpected status or a
missing capture, and the iteration stops there, because later steps usually depend on
what it would have captured.

| name | what one iteration does |
|---|---|
| `healthz` | `GET /healthz`: Puma, Sinatra, one `SELECT 1` |
| `account` | `GET /v1/account` with a key: authentication (one indexed lookup) and versioned rendering |
| `create-confirm` | `POST /v1/payment_intents` (1000 usd, `pm_card_visa`, automatic capture), capture `id`, then `POST /v1/payment_intents/{id}/confirm` |
| `confirm` | confirm only. The intents are created before the run, closed loop and unmeasured, one per planned iteration |

Every create and confirm carries its own `Idempotency-Key`,
`lg-<run>-<iter>-<step>`, so no two requests in a run share a key and a rerun never
replays an old one. Experiment 1's storm needs the opposite (K concurrent confirms under
one key); `ScenarioTarget` and `Run` are exported so a storm driver can build that on
top without a second HTTP harness.

**Why a prepare phase for `confirm`.** Experiment 8 asks for latency of `confirm`. Timing
create and confirm together measures a different thing, and timing only the confirm step
inside create-confirm loses the intended-time correction (its intended time would be the
create's). So `confirm` creates exactly as many intents as the schedule will use, then
runs the measured phase against them. If some creates fail, the shortfall shows up as
`no_prepared_state` errors in the measured run, not as a shorter run.

A scenario that needs a key takes `-key` (or `$CLEARINGHOUSE_KEY`). With neither, and
`-admin-token` (or `$CLEARINGHOUSE_ADMIN_TOKEN`) set, the generator creates a merchant
through `POST /v1/merchants` first.

The create body matches the payments routes as they stand: `amount`, `currency`,
`payment_method`, `capture_method`. I left out `confirm=false`: it is Stripe's default,
and the create route on the payments branch does not list `confirm` as a permitted
parameter, so sending it would be a 400 `parameter_unknown`.

## Rate sweep

`loadgen sweep -rates 25,50,100,200 -slo-p99 250ms -warmup 5s -duration 30s` runs the
rates in ascending order, each with its own warmup and (for `confirm`) its own prepared
intents, and reports the highest rate at which p99 response time is within the
objective and the error rate is at most `-max-error-rate` (default 0.1%), **with every
lower rate passing too**. A rate that passes above a failing one is noise, not capacity.
The sweep stops at the first failure unless `-keep-going`, since past saturation every
higher rate fails and only takes longer to say so.

## Output

Every run prints a table and, with `-out` (the wrapper defaults to
`results/raw/loadgen/<UTC time>-<mode>-<scenario>/`), writes:

- `summary.json`: target, whether it is loopback, scenario, arrival, seed, rate,
  duration, warmup, cap, planned/sent/completed/ok/late/dropped counts, target versus
  scheduled, sent and completed rates, errors by class and group, the three histograms'
  p50/p90/p99/p99.9/max/mean in ms, per-step service times, and the machine: GOOS,
  GOARCH, CPU count, CPU brand and memory (`sysctl` on macOS, `/proc` on Linux), Go
  version and a free-text `-label`, plus a timestamp.
- `response.hgrm`, `service.hgrm`, `send_delay.hgrm`: HdrHistogram percentile
  distributions in ms, readable by HdrHistogram's plotter.
- For a sweep, one such directory per rate and `sweep.json` with the verdicts.

## Smoke test against the real server

**This is a smoke test to show the tool works end to end. It is not the experiment 8
result and these numbers should not be quoted.** The laptop was running several other
agents' test suites at the same time (load average between 25 and 70 during the runs),
so the tails below are mostly other processes taking the CPU. Experiment 8 needs a quiet
machine, the simulator at zero latency, and `confirm`.

Setup: Apple M3 Pro, 12 CPUs, 18 GiB, macOS, Go 1.26.5; `bin/server` (Puma, 5 threads,
production mode, request logging to a file) on port 4711 against Postgres 16.15 in
Docker; generator on the same host; constant arrivals, 3s warmup, 20s measured,
`-max-outstanding 64`, merchant created through the admin endpoint. Commit `98223cd`.
Command: `bin/loadtest run -target http://127.0.0.1:4711 -scenario <s> -rate <r> -duration 20s -warmup 3s`.

Response time from intended send, ms. Every request succeeded and none were dropped.

| scenario | rate/s | sent/s | p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|---|---|---|
| healthz | 50 | 50.0 | 1.494 | 2.693 | 11.119 | 67.967 | 86.271 |
| healthz | 200 | 200.0 | 2.983 | 38.399 | 985.087 | 1304.575 | 1424.383 |
| healthz | 500 | 500.0 | 3.641 | 438.527 | 1286.143 | 1709.055 | 1897.471 |
| account | 50 | 50.0 | 3.215 | 8.463 | 31.775 | 127.999 | 184.959 |
| account | 200 | 200.0 | 2.117 | 6.623 | 1405.951 | 2242.559 | 2340.863 |
| account | 500 | 500.0 | 2.001 | 6.439 | 460.287 | 697.855 | 768.511 |

That `account` at 500/s has a better p99 than at 200/s says how noisy the machine was.
An earlier 10s run of `account` at 200/s had p99 6.3ms.

The same machine, `healthz` at 200/s with `-max-outstanding 1`, which is what a
single-connection closed-loop client would see:

| ms | p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|---|
| service time | 1.639 | 3.525 | 9.719 | 27.455 | 110.463 |
| response time | 1.727 | 6.135 | 53.151 | 109.375 | 111.359 |

With one connection, every slow request holds up the ones behind it. A closed-loop
tool would have reported p99 9.7ms; the users behind those slow requests saw 53ms.

With 64 connections and only 5 Puma threads, the queueing moves into the server's
socket backlog instead: requests are "sent" on time and wait inside the server, so
service time shows it too and the two histograms nearly agree. The intended-time
measurement matters most exactly when the client cannot keep sending, which is the case
a closed-loop tool gets wrong.

A 1s `create-confirm` run against the same server returned `http_404` for all 20
iterations, because the PaymentIntent routes are not merged yet. The scenarios are
tested against a Stripe-shaped stand-in (`scenario_test.go`) until they are.

## Running experiment 8

1. Start the simulator with latency at zero (the default, `docs/design/sim.md`) and the
   server with `CLEARINGHOUSE_ADMIN_TOKEN` set, on a machine doing nothing else.
2. `bin/loadtest sweep -scenario confirm -rates 10,25,50,100,200 -warmup 10s -duration 60s -slo-p99 <objective> -label "<machine, where server and db run>"`
3. Keep the output directory; its `summary.json` files carry the machine label.

## Alternatives considered

- **wrk2** already does intended-time measurement. A multi-step flow ("create, capture
  the id, confirm with a fresh key") would be hand-written Lua per scenario, there is no
  unmeasured prepare phase, and its output is text rather than JSON with the machine
  attached.
- **A Ruby generator** would share the GVL-bound runtime with what it measures and has
  no mature HdrHistogram.
- **Correcting a closed-loop histogram afterwards** (HdrHistogram's
  `RecordCorrectedValue`, which back-fills the samples that should have been sent)
  assumes a constant expected interval and only fixes the shape afterwards. Scheduling
  in advance measures the real thing and works for Poisson arrivals too.
