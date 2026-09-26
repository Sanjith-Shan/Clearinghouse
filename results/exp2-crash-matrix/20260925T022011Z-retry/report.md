# Experiment 2: crash at every recovery point (retry mode)

**crashed at 88 points across 13 flows, recovered at all 88.**

- Command: `bin/crash-matrix --db clearinghouse_exp2` at commit 2860114-dirty
- Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker (server PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2))
- API process: Puma single mode, threads 1:4, database pool 10
- Load average (1/5/15 min): before 15.05 / 20.97 / 25.72, after 14.21 / 24.26 / 26.77
- Started 2026-09-25T02:20:11Z, took 272.1 s; lease (lock timeout) 1.0 s
- Registry: 76 crash points in 9 flows (payment_intent.create, payment_intent.confirm, payment_intent.capture, payment_intent.cancel, refund.create, review.approve, review.reject, payout.create, payout.cancel)
- Background (bin/poller): 12 crash points in 4 flows (notification.dispute.closed, notification.dispute.opened, notification.payout.failed, notification.payout.paid)
- Flows with no scenario yet (their cases fail): none

Normalisation: The recovered response is compared with an uninterrupted control request (same scenario, another Idempotency-Key, same server, same database) after rewriting exactly two things: generated ids (prefix_ plus 24 alphanumerics, the simulator's acq_ plus 24 hex, and the fake RiskGate's asm_ counter) become <prefix#n> numbered by first appearance, so references must still line up; and the value of every key named `created` (the Unix second the object was created). Status, every amount, state, error code, and key order must match exactly. The second retry of the crashed request is compared with the recovered response byte for byte, with no normalisation at all. The outcome (intent, refunds, events with their payloads, ledger, acquirer operations) is compared with the control's under the same id rule, including which request's Idempotency-Key each event carries.

| # | Crash name | Result | Recovered answer | Total s | Failed checks |
|---|---|---|---|---|---|
| 1 | `payment_intent.create:started` | pass | 200 requires_confirmation | 2.032 |  |
| 2 | `payment_intent.create:started:before_commit` | pass | 200 requires_confirmation | 2.099 |  |
| 3 | `payment_intent.create:finished` | pass | 200 requires_confirmation (replayed) | 4.413 |  |
| 4 | `payment_intent.create:finished:before_commit` | pass | 200 requires_confirmation | 3.085 |  |
| 5 | `payment_intent.confirm:started` | pass | 200 succeeded | 2.658 |  |
| 6 | `payment_intent.confirm:started:before_commit` | pass | 200 succeeded | 2.917 |  |
| 7 | `payment_intent.confirm:intent_locked` | pass | 200 succeeded | 2.802 |  |
| 8 | `payment_intent.confirm:intent_locked:before_commit` | pass | 200 succeeded | 2.884 |  |
| 9 | `payment_intent.confirm:risk_assessed` | pass | 200 succeeded | 3.404 |  |
| 10 | `payment_intent.confirm:risk_assessed:before_commit` | pass | 200 succeeded | 2.901 |  |
| 11 | `payment_intent.confirm:authorization_requested` | pass | 200 succeeded | 2.632 |  |
| 12 | `payment_intent.confirm:authorization_requested:before_commit` | pass | 200 succeeded | 2.806 |  |
| 13 | `payment_intent.confirm:authorization_recorded` | pass | 200 succeeded | 2.941 |  |
| 14 | `payment_intent.confirm:authorization_recorded:before_commit` | pass | 200 succeeded | 2.644 |  |
| 15 | `payment_intent.confirm:ledger_posted` | pass | 200 succeeded | 3.241 |  |
| 16 | `payment_intent.confirm:ledger_posted:before_commit` | pass | 200 succeeded | 2.922 |  |
| 17 | `payment_intent.confirm:finished` | pass | 200 succeeded (replayed) | 3.047 |  |
| 18 | `payment_intent.confirm:finished:before_commit` | pass | 200 succeeded | 2.92 |  |
| 19 | `payment_intent.capture:started` | pass | 200 succeeded | 2.909 |  |
| 20 | `payment_intent.capture:started:before_commit` | pass | 200 succeeded | 2.837 |  |
| 21 | `payment_intent.capture:intent_locked` | pass | 200 succeeded | 2.634 |  |
| 22 | `payment_intent.capture:intent_locked:before_commit` | pass | 200 succeeded | 3.112 |  |
| 23 | `payment_intent.capture:capture_requested` | pass | 200 succeeded | 3.819 |  |
| 24 | `payment_intent.capture:capture_requested:before_commit` | pass | 200 succeeded | 3.268 |  |
| 25 | `payment_intent.capture:capture_recorded` | pass | 200 succeeded | 4.329 |  |
| 26 | `payment_intent.capture:capture_recorded:before_commit` | pass | 200 succeeded | 7.795 |  |
| 27 | `payment_intent.capture:finished` | pass | 200 succeeded (replayed) | 7.184 |  |
| 28 | `payment_intent.capture:finished:before_commit` | pass | 200 succeeded | 3.571 |  |
| 29 | `payment_intent.cancel:started` | pass | 200 canceled | 3.571 |  |
| 30 | `payment_intent.cancel:started:before_commit` | pass | 200 canceled | 6.804 |  |
| 31 | `payment_intent.cancel:intent_locked` | pass | 200 canceled | 5.25 |  |
| 32 | `payment_intent.cancel:intent_locked:before_commit` | pass | 200 canceled | 5.782 |  |
| 33 | `payment_intent.cancel:void_requested` | pass | 200 canceled | 2.624 |  |
| 34 | `payment_intent.cancel:void_requested:before_commit` | pass | 200 canceled | 2.579 |  |
| 35 | `payment_intent.cancel:canceled` | pass | 200 canceled | 3.241 |  |
| 36 | `payment_intent.cancel:canceled:before_commit` | pass | 200 canceled | 4.878 |  |
| 37 | `payment_intent.cancel:finished` | pass | 200 canceled (replayed) | 2.577 |  |
| 38 | `payment_intent.cancel:finished:before_commit` | pass | 200 canceled | 2.538 |  |
| 39 | `refund.create:started` | pass | 200 succeeded | 2.907 |  |
| 40 | `refund.create:started:before_commit` | pass | 200 succeeded | 2.303 |  |
| 41 | `refund.create:refund_created` | pass | 200 succeeded | 2.993 |  |
| 42 | `refund.create:refund_created:before_commit` | pass | 200 succeeded | 2.718 |  |
| 43 | `refund.create:refund_requested` | pass | 200 succeeded | 2.348 |  |
| 44 | `refund.create:refund_requested:before_commit` | pass | 200 succeeded | 2.717 |  |
| 45 | `refund.create:refund_recorded` | pass | 200 succeeded | 2.438 |  |
| 46 | `refund.create:refund_recorded:before_commit` | pass | 200 succeeded | 2.866 |  |
| 47 | `refund.create:finished` | pass | 200 succeeded (replayed) | 2.912 |  |
| 48 | `refund.create:finished:before_commit` | pass | 200 succeeded | 2.458 |  |
| 49 | `review.approve:started` | pass | 200 review | 2.125 |  |
| 50 | `review.approve:started:before_commit` | pass | 200 review | 1.582 |  |
| 51 | `review.approve:finished` | pass | 200 review (replayed) | 1.747 |  |
| 52 | `review.approve:finished:before_commit` | pass | 200 review | 2.201 |  |
| 53 | `review.reject:started` | pass | 200 review | 2.885 |  |
| 54 | `review.reject:started:before_commit` | pass | 200 review | 2.016 |  |
| 55 | `review.reject:refund_created` | pass | 200 review | 2.149 |  |
| 56 | `review.reject:refund_created:before_commit` | pass | 200 review | 2.12 |  |
| 57 | `review.reject:refund_requested` | pass | 200 review | 2.173 |  |
| 58 | `review.reject:refund_requested:before_commit` | pass | 200 review | 2.088 |  |
| 59 | `review.reject:refund_recorded` | pass | 200 review | 2.32 |  |
| 60 | `review.reject:refund_recorded:before_commit` | pass | 200 review | 2.943 |  |
| 61 | `review.reject:finished` | pass | 200 review (replayed) | 2.206 |  |
| 62 | `review.reject:finished:before_commit` | pass | 200 review | 2.617 |  |
| 63 | `payout.create:started` | pass | 200 in_transit | 2.159 |  |
| 64 | `payout.create:started:before_commit` | pass | 200 in_transit | 2.173 |  |
| 65 | `payout.create:balance_reserved` | pass | 200 in_transit | 2.169 |  |
| 66 | `payout.create:balance_reserved:before_commit` | pass | 200 in_transit | 2.28 |  |
| 67 | `payout.create:bank_requested` | pass | 200 in_transit | 2.227 |  |
| 68 | `payout.create:bank_requested:before_commit` | pass | 200 in_transit | 2.328 |  |
| 69 | `payout.create:bank_recorded` | pass | 200 in_transit | 2.323 |  |
| 70 | `payout.create:bank_recorded:before_commit` | pass | 200 in_transit | 2.626 |  |
| 71 | `payout.create:finished` | pass | 200 in_transit (replayed) | 1.867 |  |
| 72 | `payout.create:finished:before_commit` | pass | 200 in_transit | 2.229 |  |
| 73 | `payout.cancel:started` | pass | 200 canceled | 2.633 |  |
| 74 | `payout.cancel:started:before_commit` | pass | 200 canceled | 2.446 |  |
| 75 | `payout.cancel:finished` | pass | 200 canceled (replayed) | 2.003 |  |
| 76 | `payout.cancel:finished:before_commit` | pass | 200 canceled | 2.372 |  |
| 77 | `notification.dispute.closed:notification_fetched` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"2"} | 3.508 |  |
| 78 | `notification.dispute.closed:effects_written` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"2"} | 3.875 |  |
| 79 | `notification.dispute.closed:committed` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"2"} | 3.987 |  |
| 80 | `notification.dispute.opened:notification_fetched` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 4.114 |  |
| 81 | `notification.dispute.opened:effects_written` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 3.525 |  |
| 82 | `notification.dispute.opened:committed` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 3.762 |  |
| 83 | `notification.payout.failed:notification_fetched` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 3.127 |  |
| 84 | `notification.payout.failed:effects_written` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 3.24 |  |
| 85 | `notification.payout.failed:committed` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 3.315 |  |
| 86 | `notification.payout.paid:notification_fetched` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 4.924 |  |
| 87 | `notification.payout.paid:effects_written` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 4.34 |  |
| 88 | `notification.payout.paid:committed` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 3.725 |  |
| 89 | `payment_intent.confirm:authorization_requested+acquirer_drop` | pass | 200 succeeded | 2.417 |  |
