# Experiment 1: retry storm

Method, the interleavings behind each baseline's failures, and how to read these tables:
`docs/design/storm.md`.

Each directory is one `bin/storm` run, holding `results.json` (everything, including
histograms and the plan) and `results.md` (the table plus command, machine, load, server
threads and DB pool). The label is in the directory name. So far there are only **smoke**
runs (20 intents × K = 8, drop rate 0.2), made on a shared machine with a load average of
50 to 70:

- `20260924T011042Z-smoke-fail`: all three implementations, baselines fail the attempt on a lost answer.
- `20260924T011155Z-smoke-hold`: the two baselines, holding the intent in processing instead.

The full run is still to be made on a quiet machine.
