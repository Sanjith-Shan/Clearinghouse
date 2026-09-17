# Experiment 2: crash at every recovery point (retry mode)

**crashed at 48 points across 5 flows, recovered at all 48.**

- Command: `bin/crash-matrix`
- Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker (server PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2))
- Load average (1/5/15 min): before 44.22 / 44.55 / 45.55, after 44.55 / 57.05 / 56.4
- Started 2026-09-24T01:01:11Z, took 819.6 s; lease (lock timeout) 1.0 s
- Registry: 48 crash points in 5 flows (payment_intent.create, payment_intent.confirm, payment_intent.capture, payment_intent.cancel, refund.create)

Normalisation: The recovered response is compared with an uninterrupted control request (same scenario, another Idempotency-Key, same server, same database) after rewriting exactly two things: generated ids (prefix_ plus 24 alphanumerics, the simulator's acq_ plus 24 hex, and the fake RiskGate's asm_ counter) become <prefix#n> numbered by first appearance, so references must still line up; and the value of every key named `created` (the Unix second the object was created). Status, every amount, state, error code, and key order must match exactly. The second retry of the crashed request is compared with the recovered response byte for byte, with no normalisation at all.

| # | Crash name | Result | Recovered answer | Total s | Failed checks |
|---|---|---|---|---|---|
| 1 | `payment_intent.create:started` | pass | 200 requires_confirmation | 16.021 |  |
| 2 | `payment_intent.create:started:before_commit` | pass | 200 requires_confirmation | 21.928 |  |
| 3 | `payment_intent.create:finished` | pass | 200 requires_confirmation (replayed) | 17.99 |  |
| 4 | `payment_intent.create:finished:before_commit` | pass | 200 requires_confirmation | 17.923 |  |
| 5 | `payment_intent.confirm:started` | pass | 200 succeeded | 15.48 |  |
| 6 | `payment_intent.confirm:started:before_commit` | pass | 200 succeeded | 13.675 |  |
| 7 | `payment_intent.confirm:intent_locked` | pass | 200 succeeded | 16.727 |  |
| 8 | `payment_intent.confirm:intent_locked:before_commit` | pass | 200 succeeded | 16.147 |  |
| 9 | `payment_intent.confirm:risk_assessed` | pass | 200 succeeded | 18.724 |  |
| 10 | `payment_intent.confirm:risk_assessed:before_commit` | pass | 200 succeeded | 15.799 |  |
| 11 | `payment_intent.confirm:authorization_requested` | pass | 200 succeeded | 8.919 |  |
| 12 | `payment_intent.confirm:authorization_requested:before_commit` | pass | 200 succeeded | 15.065 |  |
| 13 | `payment_intent.confirm:authorization_recorded` | pass | 200 succeeded | 18.671 |  |
| 14 | `payment_intent.confirm:authorization_recorded:before_commit` | pass | 200 succeeded | 20.049 |  |
| 15 | `payment_intent.confirm:ledger_posted` | pass | 200 succeeded | 18.671 |  |
| 16 | `payment_intent.confirm:ledger_posted:before_commit` | pass | 200 succeeded | 17.79 |  |
| 17 | `payment_intent.confirm:finished` | pass | 200 succeeded (replayed) | 19.78 |  |
| 18 | `payment_intent.confirm:finished:before_commit` | pass | 200 succeeded | 9.595 |  |
| 19 | `payment_intent.capture:started` | pass | 200 succeeded | 17.831 |  |
| 20 | `payment_intent.capture:started:before_commit` | pass | 200 succeeded | 12.827 |  |
| 21 | `payment_intent.capture:intent_locked` | pass | 200 succeeded | 11.829 |  |
| 22 | `payment_intent.capture:intent_locked:before_commit` | pass | 200 succeeded | 12.952 |  |
| 23 | `payment_intent.capture:capture_requested` | pass | 200 succeeded | 19.082 |  |
| 24 | `payment_intent.capture:capture_requested:before_commit` | pass | 200 succeeded | 18.565 |  |
| 25 | `payment_intent.capture:capture_recorded` | pass | 200 succeeded | 17.436 |  |
| 26 | `payment_intent.capture:capture_recorded:before_commit` | pass | 200 succeeded | 18.537 |  |
| 27 | `payment_intent.capture:finished` | pass | 200 succeeded (replayed) | 17.159 |  |
| 28 | `payment_intent.capture:finished:before_commit` | pass | 200 succeeded | 15.028 |  |
| 29 | `payment_intent.cancel:started` | pass | 200 canceled | 18.351 |  |
| 30 | `payment_intent.cancel:started:before_commit` | pass | 200 canceled | 13.246 |  |
| 31 | `payment_intent.cancel:intent_locked` | pass | 200 canceled | 12.611 |  |
| 32 | `payment_intent.cancel:intent_locked:before_commit` | pass | 200 canceled | 12.426 |  |
| 33 | `payment_intent.cancel:void_requested` | pass | 200 canceled | 11.066 |  |
| 34 | `payment_intent.cancel:void_requested:before_commit` | pass | 200 canceled | 13.179 |  |
| 35 | `payment_intent.cancel:canceled` | pass | 200 canceled | 20.239 |  |
| 36 | `payment_intent.cancel:canceled:before_commit` | pass | 200 canceled | 23.156 |  |
| 37 | `payment_intent.cancel:finished` | pass | 200 canceled (replayed) | 20.72 |  |
| 38 | `payment_intent.cancel:finished:before_commit` | pass | 200 canceled | 15.502 |  |
| 39 | `refund.create:started` | pass | 200 succeeded | 18.244 |  |
| 40 | `refund.create:started:before_commit` | pass | 200 succeeded | 16.523 |  |
| 41 | `refund.create:refund_created` | pass | 200 succeeded | 24.519 |  |
| 42 | `refund.create:refund_created:before_commit` | pass | 200 succeeded | 19.355 |  |
| 43 | `refund.create:refund_requested` | pass | 200 succeeded | 15.98 |  |
| 44 | `refund.create:refund_requested:before_commit` | pass | 200 succeeded | 13.027 |  |
| 45 | `refund.create:refund_recorded` | pass | 200 succeeded | 14.057 |  |
| 46 | `refund.create:refund_recorded:before_commit` | pass | 200 succeeded | 18.934 |  |
| 47 | `refund.create:finished` | pass | 200 succeeded (replayed) | 12.589 |  |
| 48 | `refund.create:finished:before_commit` | pass | 200 succeeded | 18.291 |  |
| 49 | `payment_intent.confirm:authorization_requested+acquirer_drop` | pass | 200 succeeded | 21.102 |  |
