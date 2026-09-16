# Experiment 2: crash at every recovery point (completer mode)

**crashed at 48 points across 5 flows, recovered at all 48.**

- Command: `bin/crash-matrix --recovery completer` at commit 96880c6
- Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker (server PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2))
- API process: Puma single mode, threads 1:4, database pool 10
- Load average (1/5/15 min): before 48.05 / 53.79 / 54.22, after 38.64 / 42.18 / 46.97
- Started 2026-09-24T01:45:51Z, took 742.6 s; lease (lock timeout) 1.0 s
- Registry: 48 crash points in 5 flows (payment_intent.create, payment_intent.confirm, payment_intent.capture, payment_intent.cancel, refund.create)
- Flows with no scenario yet (their cases fail): none

Normalisation: The recovered response is compared with an uninterrupted control request (same scenario, another Idempotency-Key, same server, same database) after rewriting exactly two things: generated ids (prefix_ plus 24 alphanumerics, the simulator's acq_ plus 24 hex, and the fake RiskGate's asm_ counter) become <prefix#n> numbered by first appearance, so references must still line up; and the value of every key named `created` (the Unix second the object was created). Status, every amount, state, error code, and key order must match exactly. The second retry of the crashed request is compared with the recovered response byte for byte, with no normalisation at all. The outcome (intent, refunds, events with their payloads, ledger, acquirer operations) is compared with the control's under the same id rule, including which request's Idempotency-Key each event carries.

| # | Crash name | Result | Recovered answer | Total s | Failed checks |
|---|---|---|---|---|---|
| 1 | `payment_intent.create:started` | pass | retry after completer: 200 requires_confirmation (replayed) | 24.608 |  |
| 2 | `payment_intent.create:started:before_commit` | pass | retry after completer: 200 requires_confirmation | 18.685 |  |
| 3 | `payment_intent.create:finished` | pass | retry after completer: 200 requires_confirmation (replayed) | 14.28 |  |
| 4 | `payment_intent.create:finished:before_commit` | pass | retry after completer: 200 requires_confirmation (replayed) | 12.534 |  |
| 5 | `payment_intent.confirm:started` | pass | retry after completer: 200 succeeded (replayed) | 21.03 |  |
| 6 | `payment_intent.confirm:started:before_commit` | pass | retry after completer: 200 succeeded | 9.139 |  |
| 7 | `payment_intent.confirm:intent_locked` | pass | retry after completer: 200 succeeded (replayed) | 19.544 |  |
| 8 | `payment_intent.confirm:intent_locked:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 17.488 |  |
| 9 | `payment_intent.confirm:risk_assessed` | pass | retry after completer: 200 succeeded (replayed) | 14.493 |  |
| 10 | `payment_intent.confirm:risk_assessed:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 10.331 |  |
| 11 | `payment_intent.confirm:authorization_requested` | pass | retry after completer: 200 succeeded (replayed) | 12.684 |  |
| 12 | `payment_intent.confirm:authorization_requested:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 16.028 |  |
| 13 | `payment_intent.confirm:authorization_recorded` | pass | retry after completer: 200 succeeded (replayed) | 14.381 |  |
| 14 | `payment_intent.confirm:authorization_recorded:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 19.621 |  |
| 15 | `payment_intent.confirm:ledger_posted` | pass | retry after completer: 200 succeeded (replayed) | 20.76 |  |
| 16 | `payment_intent.confirm:ledger_posted:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 14.169 |  |
| 17 | `payment_intent.confirm:finished` | pass | retry after completer: 200 succeeded (replayed) | 6.307 |  |
| 18 | `payment_intent.confirm:finished:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 9.668 |  |
| 19 | `payment_intent.capture:started` | pass | retry after completer: 200 succeeded (replayed) | 8.588 |  |
| 20 | `payment_intent.capture:started:before_commit` | pass | retry after completer: 200 succeeded | 5.186 |  |
| 21 | `payment_intent.capture:intent_locked` | pass | retry after completer: 200 succeeded (replayed) | 9.561 |  |
| 22 | `payment_intent.capture:intent_locked:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 9.815 |  |
| 23 | `payment_intent.capture:capture_requested` | pass | retry after completer: 200 succeeded (replayed) | 9.417 |  |
| 24 | `payment_intent.capture:capture_requested:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 12.597 |  |
| 25 | `payment_intent.capture:capture_recorded` | pass | retry after completer: 200 succeeded (replayed) | 14.995 |  |
| 26 | `payment_intent.capture:capture_recorded:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 20.8 |  |
| 27 | `payment_intent.capture:finished` | pass | retry after completer: 200 succeeded (replayed) | 13.274 |  |
| 28 | `payment_intent.capture:finished:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 13.542 |  |
| 29 | `payment_intent.cancel:started` | pass | retry after completer: 200 canceled (replayed) | 12.691 |  |
| 30 | `payment_intent.cancel:started:before_commit` | pass | retry after completer: 200 canceled | 12.922 |  |
| 31 | `payment_intent.cancel:intent_locked` | pass | retry after completer: 200 canceled (replayed) | 16.524 |  |
| 32 | `payment_intent.cancel:intent_locked:before_commit` | pass | retry after completer: 200 canceled (replayed) | 17.17 |  |
| 33 | `payment_intent.cancel:void_requested` | pass | retry after completer: 200 canceled (replayed) | 18.37 |  |
| 34 | `payment_intent.cancel:void_requested:before_commit` | pass | retry after completer: 200 canceled (replayed) | 27.619 |  |
| 35 | `payment_intent.cancel:canceled` | pass | retry after completer: 200 canceled (replayed) | 15.664 |  |
| 36 | `payment_intent.cancel:canceled:before_commit` | pass | retry after completer: 200 canceled (replayed) | 23.886 |  |
| 37 | `payment_intent.cancel:finished` | pass | retry after completer: 200 canceled (replayed) | 18.949 |  |
| 38 | `payment_intent.cancel:finished:before_commit` | pass | retry after completer: 200 canceled (replayed) | 12.844 |  |
| 39 | `refund.create:started` | pass | retry after completer: 200 succeeded (replayed) | 11.318 |  |
| 40 | `refund.create:started:before_commit` | pass | retry after completer: 200 succeeded | 12.217 |  |
| 41 | `refund.create:refund_created` | pass | retry after completer: 200 succeeded (replayed) | 9.395 |  |
| 42 | `refund.create:refund_created:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 9.682 |  |
| 43 | `refund.create:refund_requested` | pass | retry after completer: 200 succeeded (replayed) | 14.509 |  |
| 44 | `refund.create:refund_requested:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 12.797 |  |
| 45 | `refund.create:refund_recorded` | pass | retry after completer: 200 succeeded (replayed) | 18.275 |  |
| 46 | `refund.create:refund_recorded:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 19.256 |  |
| 47 | `refund.create:finished` | pass | retry after completer: 200 succeeded (replayed) | 15.17 |  |
| 48 | `refund.create:finished:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 17.102 |  |
| 49 | `payment_intent.confirm:authorization_requested+acquirer_drop` | pass | retry after completer: 200 succeeded (replayed) | 21.865 |  |
