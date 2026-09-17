# Experiment 5: reconciliation under injected discrepancies

Design and scoring rules: `docs/design/reconciliation.md`, "Experiment 5". Code:
`bin/exp-reconciliation`, `lib/clearinghouse/experiments/`.

## Smoke run (seed 1)

This is a smoke-sized run, not the published month. It was taken while the machine was
heavily loaded by other work (load average 40 to 50 on 12 cores), which affects the wall
time and nothing else: every number below is a count from the ledger, the reconciler and
the simulator's manifests. The full-size run (1,500 payments over 30 days, 60
discrepancies) is `bin/exp-reconciliation --reset` and is to be taken on a quiet machine.

- Command: `CLEARINGHOUSE_DB=clearinghouse_test_disputes CLEARINGHOUSE_ENV=experiment bin/exp-reconciliation --reset --smoke`
- Machine: Apple M3 Pro, 12 cores, 18 GB. PostgreSQL 16.15 in Docker (docker compose,
  container `clearinghouse-db-1`). Database pool 8. Simulator and API in the same process on
  local ports.
- Workload: 120 payments planned over 10 days plus 14 quiet days, 3 merchants (USD, JPY,
  KWD). Everything goes through the API with the Ruby client library; 3 of the payments go
  through a second API instance whose clock runs two days behind. 122 payments succeeded
  (119 of the 120 planned, 1 declined, plus the 3 lagging ones), 19 refunds, 7 disputes
  (3 won, 4 lost; 2 accepted by the merchant first), 28 payouts sent and paid through
  `POST /v1/payouts` (35 daily attempts found no positive available balance). 24 settlement
  files, 150 lines.
- Raw output: `seed-1-smoke.json`. Wall time 111.9 s.

| discrepancy | injected | detected |
|---|---:|---:|
| missing | 2 | 2 |
| duplicate | 0 | 0 |
| amount_mismatch | 4 | 4 |
| fee_mismatch | 3 | 3 |
| late | 2 | 2 |
| unknown_payment | 1 | 1 |
| **total** | **12** | **12** |

- False exceptions: **0**. Detected as another type: 0. Undetected: 0.
- Lines the acquirer carried over on its own (not injected): 3; called late: 0.
- Ledger invariant violations: 0 before and after resolving. Balance drifts: 0.

The seeded random injection drew no `duplicate` in this small run, so this run says nothing
about duplicates; `spec/settlement/reconciler_spec.rb` covers them, and the full run
injects all six types.

Explainability (share of volume in flows whose clearing accounts are back at zero) at the
end of the tail:

| flow type | currency | flows | before resolving | after resolving |
|---|---|---:|---:|---:|
| dispute | jpy | 5 | 100.00% | 100.00% |
| dispute | usd | 2 | 100.00% | 100.00% |
| payment | jpy | 49 | 92.06% | 100.00% |
| payment | kwd | 34 | 92.51% | 100.00% |
| payment | usd | 39 | 96.38% | 100.00% |
| payout | jpy | 10 | 100.00% | 100.00% |
| payout | kwd | 9 | 100.00% | 100.00% |
| payout | usd | 9 | 100.00% | 100.00% |
| refund | jpy | 9 | 100.00% | 100.00% |
| refund | kwd | 5 | 91.60% | 100.00% |
| refund | usd | 5 | 100.00% | 100.00% |

Before resolving, the unexplained flows are exactly the ones with money stuck by a
discrepancy: missing lines and mismatched amounts or fees. Resolving the 10 open exceptions
(9 write-offs, 1 note-only for the unknown payment) brings every flow type to 100%.

Funds availability and payouts are the payouts work's own (the availability job and
`POST /v1/payouts`), and payout notifications go through the same poller as disputes.
