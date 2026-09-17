# Wall-clock assertions in the specs

A few specs assert how long something takes in real time: the RiskGate client's deadline
(`spec/risk/client_spec.rb`) and experiment 9's short run (`spec/experiments/risk_failure_spec.rb`).
On a quiet machine the tight bounds hold with room to spare. On the shared development machine
at a load average of 60, one connect-deadline call measured 1,066 ms against a 120 ms bound,
and experiment 9's healthy phase after recovery saw unchecked payments, because a healthy
RiskGate on a starved machine misses a 50 ms deadline too. Those failures say the machine was
busy, not that the code was wrong, and a flaky gate trains people to rerun it until it passes.

So each such assertion has two forms, and neither was deleted:

- **Load-tolerant, always run.** It asserts what would still be false if the code were wrong,
  whatever the load:
  - the client's deadline examples check the result is a timeout (the client gave up before
    the answer arrived) and that the call ended within `deadline + epsilon + 4 x lag`, where
    `lag` is measured in the same example as the worst overrun of five 5 ms sleeps. A client
    that waited again after the deadline, or used a per-read timeout, overruns by another full
    wait on a quiet machine, and by the whole hang, drip (over a second) or kernel handshake
    timeout (over a minute) under load. The refused-connection example uses `20 ms + 4 x lag`.
  - experiment 9's run checks RiskGate recovered: fewer than half the calls after recovery
    are unchecked, and any that are unchecked failed only by timeout or the open breaker, never
    by an error from RiskGate.
- **Strict, tagged `:timing`.** The original bounds, unchanged: overrun at most one 40 ms
  wake-up, a refusal in under 20 ms, zero unchecked payments after recovery, and no step in the
  frozen phase over 90 ms. `spec/spec_helper.rb` excludes `:timing` unless
  `CLEARINGHOUSE_STRICT_TIMING=1`, so `CLEARINGHOUSE_STRICT_TIMING=1 bin/ci` on a quiet machine
  (or in CI with a dedicated runner) is the full check.

I considered only raising the bounds. A bound loose enough for a load of 60 (over a second
for an 80 ms deadline) would pass a client that waits twice, so it would stop testing the one
property the deadline exists for. Measuring the lag in the example keeps the bound tight when
the machine is quiet and loosens it only by what the machine is demonstrably costing right then.
The lag probe can itself be unlucky (a stall right after it), which is why the multiplier is 4
and why the strict twin exists.
