# Experiment 9, client level: RiskGate fails mid-run

A steady 100 risk steps per second go through `Risk::Step` / `Risk::Client` (deadline 50 ms,
breaker at its defaults: 5 consecutive failures or 50% over 10 s, 2 s cool-down). The run is
10 s healthy, then 10 s with RiskGate down, then 10 s after it comes back. There are two
kinds of failure:

- **kill**: `SIGKILL`, then a new process is started. While it is down, connections are
  refused.
- **freeze**: `SIGSTOP`, then `SIGCONT`. Connections are accepted and nothing answers.
  This is the case the deadline exists for.

Each runs against `bin/fake-riskgate` (latency p50 1 ms, p99 5 ms) and against the real
RiskGate (built from `~/Documents/RiskGate` at 8fc20b1, `-model models/ieee`, snapshots
every 5 s). Real runs send bodies from RiskGate's **synthetic** replay file, read in place.
Only aggregates are written here.

This is the client-level version. The end-to-end version through `confirm` waits for the
payments area's confirm flow.

- Machine: Apple M3 Pro, 12 cores, 18 GB, macOS 26.5.1, Ruby 3.3.12, Go 1.26.5. No Postgres
  involved.
- Command: `bin/exp-risk-failure --rate 100 --riskgate-bin <riskgate binary>` (32 worker
  threads, open loop, latency measured from each call's scheduled time).
- **The machine was shared and heavily loaded** (1-minute load average 15 to 46 on 12 cores
  during these runs, from other build sessions). Each JSON file records its load average.
  Read the healthy-phase tails with that in mind (see "What load did" below).

Per-run tables: `*.md`. Full data, including per-second counts and breaker transitions: `*.json`.

## Unchecked payments: the cost of failing open

| run | calls | unchecked total | during the 10 s outage | after restart, before the first checked payment | seconds from restart to first checked payment |
|---|---|---|---|---|---|
| fake, kill | 3000 | 1209 | 1000 | 209 | 2.10 |
| fake, freeze | 3000 | 1038 | 1000 | 34 | 0.35 |
| RiskGate, kill | 3000 | 1627 | 1001 | 207 | 2.08 |
| RiskGate, freeze | 3000 | 1033 | 1000 | 33 | 0.34 |

Every payment during the outage went through unchecked, 100 per second, as designed. The
part worth knowing is the **tail after RiskGate comes back**. After a kill, the probe that
fires right after the restart finds the process still starting and fails. The breaker then
waits a full 2 s cool-down before it probes again, so about 2 s (about 200 payments here)
go through unchecked with RiskGate already up. After a freeze, the process answers at once
and the tail is about 0.35 s. The cool-down is the knob: halving it halves the kill tail and
doubles the probes, each of which costs one payment up to the deadline during an outage.

The RiskGate kill run has 419 more unchecked payments than the outage explains. They came
from host load, not from the fault (next section).

## The step stays bounded by the deadline

Step service time (ms) in the phases the fault controls:

| run | down, breaker still closed: calls / max | breaker open: calls / p99 / max |
|---|---|---|
| fake, kill | 5 / 5.1 | 995 / 1.5 / 6.3 |
| fake, freeze | 10 / 57.3 | 990 / 2.3 / 55.7 |
| RiskGate, kill | 5 / 2.0 | 996 / 1.5 / 10.1 |
| RiskGate, freeze | 10 / 55.3 | 990 / 0.9 / 55.2 |

- **Freeze** is the expensive failure. The first calls after the freeze each wait the full
  deadline, and none exceeded 57.3 ms (deadline plus 7.3 ms). There were 10 of them, not 5,
  because at 100/s about 5 calls are in flight in any 50 ms. The breaker opened about 0.1 s
  after the freeze. From then on a call costs about 1 to 2 ms at p99, and that is the
  client's own overhead on a loaded host, since no request is sent. The ~55 ms maxima in the
  breaker-open phase are the half-open probes, one every 2 s, each of which waits out the
  deadline.
- **Kill** is cheap from the start: refused connections fail in about a millisecond, and
  the breaker opens after 5 of them.

## What load did

At 1-minute load averages of 15 to 46, the client process and RiskGate were both short of
CPU at times. In the RiskGate kill run, 10 calls in the *healthy* phase timed out. Five of
them came in a row, which opened the breaker at 7.5 s while RiskGate was up, so about 2 s of
payments (204) went unchecked for no reason. The same thing happened again at 28 s. Healthy-phase
scheduled-time latency had a p99 of 26.6 and 43.7 ms in the two kill runs and 9.2 and 7.7 ms
in the two freeze runs. The load averages don't separate these cleanly, so I can't attribute
the difference more precisely than "the host was busy". These are measurements of this client on a starved host, not of
RiskGate.

Two things follow, and I'm stating them as open, not settled:

- The deadline bounds how long the client *waits on the socket*. It can't make the OS
  schedule the thread. On a starved host a call can finish past deadline plus overhead
  without any RiskGate fault (a queueing max of 91.7 ms in the fake-kill healthy-after phase).
- Five consecutive timeouts is an aggressive trip on a host that can stall for 50 ms. A
  false open costs one cool-down of unchecked payments. The rate rule (50% over 10 s, at
  least 20 calls) would not have tripped on those bursts. Raising the run threshold, or
  counting only timeouts that also reach a failure rate, is the change to test once there
  is a quiet machine to measure on. These runs are too noisy to tune from.

A rerun on an idle machine should replace these numbers before any of them are quoted.
