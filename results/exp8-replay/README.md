# Experiment 8: the replay through Clearinghouse and RiskGate

The method, what is real and what is simulated, the assumed 15.00 USD dispute fee, and the
commands for the full runs: `docs/design/replay.md`.

Each directory is one set of `bin/exp-replay` runs, with `<policy>.json` (everything) and
`<policy>.md` (the tables plus the command, machine, load and RiskGate ruleset). Only
aggregates are stored, never rows.

So far there is only a **smoke** run, made on a shared machine with a load average of
about 10:

- `20260924T200001Z-smoke/`: the first 50 rows of RiskGate's **synthetic** export, under `none` and
  under `model_rules` against the fake RiskGate with made-up rules
  (`sim/experiments/replay/fake_policy.json`). It checks that the pieces connect. Its
  money and latency say nothing about RiskGate.

The full runs on the real test month, one per policy, are still to be made on a quiet
machine.
