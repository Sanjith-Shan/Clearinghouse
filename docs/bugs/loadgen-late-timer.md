# The generator added about a millisecond to every sample at low rates

**What broke.** The dispatcher slept on a Go timer until each request's intended send
time. When the process has been idle between requests, the timer and the worker it hands
off to wake up late, by around a millisecond on macOS. Latency is measured from the
intended time, so that lateness was added to every response time: at 50/s against
`/healthz` the median send delay was 0.67ms, and 1.03ms on `/v1/account`, against p50 response times of
2 to 4ms. The numbers were not wrong in the sense of hiding anything (the delay was counted,
not omitted), but they described the generator, not the server.

**Caught by.** The first smoke run of `bin/loadtest` against `bin/server`: the
`send delay` row of the report showed p50 0.672ms at 50/s and 0.170ms at 500/s, the
opposite of what queueing would do. A probe against an empty local handler reproduced it
(p50 0.8ms to 1.05ms at 50/s) with no server work at all.

**Fix.** The dispatcher sleeps until `SpinWindow` (default 1ms) before the intended time
and busy-waits the rest. Median send delay at 50/s on the same handler went to about
0.012ms. `TestSpinWindowKeepsSendDelayBelowAMillisecond` keeps it there. Commit 542ebb5
("Spin the last millisecond before each send", branch `pr/loadgen-scenarios`).
