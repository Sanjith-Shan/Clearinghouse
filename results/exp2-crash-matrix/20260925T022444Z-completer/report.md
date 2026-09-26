# Experiment 2: crash at every recovery point (completer mode)

**crashed at 88 points across 13 flows, recovered at all 88.**

- Command: `bin/crash-matrix --recovery completer --db clearinghouse_exp2` at commit 2860114-dirty
- Machine: Apple M3 Pro, 12 cores, 18 GB, Postgres 16 in Docker (server PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2))
- API process: Puma single mode, threads 1:4, database pool 10
- Load average (1/5/15 min): before 14.21 / 24.26 / 26.77, after 30.48 / 38.1 / 33.98
- Started 2026-09-25T02:24:44Z, took 454.3 s; lease (lock timeout) 1.0 s
- Registry: 76 crash points in 9 flows (payment_intent.create, payment_intent.confirm, payment_intent.capture, payment_intent.cancel, refund.create, review.approve, review.reject, payout.create, payout.cancel)
- Background (bin/poller): 12 crash points in 4 flows (notification.dispute.closed, notification.dispute.opened, notification.payout.failed, notification.payout.paid)
- Flows with no scenario yet (their cases fail): none

Normalisation: The recovered response is compared with an uninterrupted control request (same scenario, another Idempotency-Key, same server, same database) after rewriting exactly two things: generated ids (prefix_ plus 24 alphanumerics, the simulator's acq_ plus 24 hex, and the fake RiskGate's asm_ counter) become <prefix#n> numbered by first appearance, so references must still line up; and the value of every key named `created` (the Unix second the object was created). Status, every amount, state, error code, and key order must match exactly. The second retry of the crashed request is compared with the recovered response byte for byte, with no normalisation at all. The outcome (intent, refunds, events with their payloads, ledger, acquirer operations) is compared with the control's under the same id rule, including which request's Idempotency-Key each event carries.

| # | Crash name | Result | Recovered answer | Total s | Failed checks |
|---|---|---|---|---|---|
| 1 | `payment_intent.create:started` | pass | retry after completer: 200 requires_confirmation (replayed) | 3.8 |  |
| 2 | `payment_intent.create:started:before_commit` | pass | retry after completer: 200 requires_confirmation | 3.363 |  |
| 3 | `payment_intent.create:finished` | pass | retry after completer: 200 requires_confirmation (replayed) | 2.27 |  |
| 4 | `payment_intent.create:finished:before_commit` | pass | retry after completer: 200 requires_confirmation (replayed) | 2.473 |  |
| 5 | `payment_intent.confirm:started` | pass | retry after completer: 200 succeeded (replayed) | 2.708 |  |
| 6 | `payment_intent.confirm:started:before_commit` | pass | retry after completer: 200 succeeded | 1.646 |  |
| 7 | `payment_intent.confirm:intent_locked` | pass | retry after completer: 200 succeeded (replayed) | 2.791 |  |
| 8 | `payment_intent.confirm:intent_locked:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 3.274 |  |
| 9 | `payment_intent.confirm:risk_assessed` | pass | retry after completer: 200 succeeded (replayed) | 4.009 |  |
| 10 | `payment_intent.confirm:risk_assessed:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 3.61 |  |
| 11 | `payment_intent.confirm:authorization_requested` | pass | retry after completer: 200 succeeded (replayed) | 4.496 |  |
| 12 | `payment_intent.confirm:authorization_requested:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 3.693 |  |
| 13 | `payment_intent.confirm:authorization_recorded` | pass | retry after completer: 200 succeeded (replayed) | 3.257 |  |
| 14 | `payment_intent.confirm:authorization_recorded:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 3.46 |  |
| 15 | `payment_intent.confirm:ledger_posted` | pass | retry after completer: 200 succeeded (replayed) | 3.766 |  |
| 16 | `payment_intent.confirm:ledger_posted:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 3.522 |  |
| 17 | `payment_intent.confirm:finished` | pass | retry after completer: 200 succeeded (replayed) | 2.521 |  |
| 18 | `payment_intent.confirm:finished:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 3.536 |  |
| 19 | `payment_intent.capture:started` | pass | retry after completer: 200 succeeded (replayed) | 3.797 |  |
| 20 | `payment_intent.capture:started:before_commit` | pass | retry after completer: 200 succeeded | 2.663 |  |
| 21 | `payment_intent.capture:intent_locked` | pass | retry after completer: 200 succeeded (replayed) | 3.661 |  |
| 22 | `payment_intent.capture:intent_locked:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 3.654 |  |
| 23 | `payment_intent.capture:capture_requested` | pass | retry after completer: 200 succeeded (replayed) | 4.143 |  |
| 24 | `payment_intent.capture:capture_requested:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 4.442 |  |
| 25 | `payment_intent.capture:capture_recorded` | pass | retry after completer: 200 succeeded (replayed) | 3.841 |  |
| 26 | `payment_intent.capture:capture_recorded:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 3.613 |  |
| 27 | `payment_intent.capture:finished` | pass | retry after completer: 200 succeeded (replayed) | 2.592 |  |
| 28 | `payment_intent.capture:finished:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 5.737 |  |
| 29 | `payment_intent.cancel:started` | pass | retry after completer: 200 canceled (replayed) | 3.774 |  |
| 30 | `payment_intent.cancel:started:before_commit` | pass | retry after completer: 200 canceled | 3.167 |  |
| 31 | `payment_intent.cancel:intent_locked` | pass | retry after completer: 200 canceled (replayed) | 3.557 |  |
| 32 | `payment_intent.cancel:intent_locked:before_commit` | pass | retry after completer: 200 canceled (replayed) | 3.481 |  |
| 33 | `payment_intent.cancel:void_requested` | pass | retry after completer: 200 canceled (replayed) | 4.723 |  |
| 34 | `payment_intent.cancel:void_requested:before_commit` | pass | retry after completer: 200 canceled (replayed) | 4.896 |  |
| 35 | `payment_intent.cancel:canceled` | pass | retry after completer: 200 canceled (replayed) | 4.517 |  |
| 36 | `payment_intent.cancel:canceled:before_commit` | pass | retry after completer: 200 canceled (replayed) | 7.889 |  |
| 37 | `payment_intent.cancel:finished` | pass | retry after completer: 200 canceled (replayed) | 3.539 |  |
| 38 | `payment_intent.cancel:finished:before_commit` | pass | retry after completer: 200 canceled (replayed) | 4.245 |  |
| 39 | `refund.create:started` | pass | retry after completer: 200 succeeded (replayed) | 5.659 |  |
| 40 | `refund.create:started:before_commit` | pass | retry after completer: 200 succeeded | 3.153 |  |
| 41 | `refund.create:refund_created` | pass | retry after completer: 200 succeeded (replayed) | 4.514 |  |
| 42 | `refund.create:refund_created:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 4.304 |  |
| 43 | `refund.create:refund_requested` | pass | retry after completer: 200 succeeded (replayed) | 4.164 |  |
| 44 | `refund.create:refund_requested:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 4.595 |  |
| 45 | `refund.create:refund_recorded` | pass | retry after completer: 200 succeeded (replayed) | 4.09 |  |
| 46 | `refund.create:refund_recorded:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 4.459 |  |
| 47 | `refund.create:finished` | pass | retry after completer: 200 succeeded (replayed) | 4.696 |  |
| 48 | `refund.create:finished:before_commit` | pass | retry after completer: 200 succeeded (replayed) | 12.145 |  |
| 49 | `review.approve:started` | pass | retry after completer: 200 review (replayed) | 5.242 |  |
| 50 | `review.approve:started:before_commit` | pass | retry after completer: 200 review | 4.658 |  |
| 51 | `review.approve:finished` | pass | retry after completer: 200 review (replayed) | 5.511 |  |
| 52 | `review.approve:finished:before_commit` | pass | retry after completer: 200 review (replayed) | 7.781 |  |
| 53 | `review.reject:started` | pass | retry after completer: 200 review (replayed) | 4.231 |  |
| 54 | `review.reject:started:before_commit` | pass | retry after completer: 200 review | 3.477 |  |
| 55 | `review.reject:refund_created` | pass | retry after completer: 200 review (replayed) | 4.269 |  |
| 56 | `review.reject:refund_created:before_commit` | pass | retry after completer: 200 review (replayed) | 4.905 |  |
| 57 | `review.reject:refund_requested` | pass | retry after completer: 200 review (replayed) | 4.619 |  |
| 58 | `review.reject:refund_requested:before_commit` | pass | retry after completer: 200 review (replayed) | 4.086 |  |
| 59 | `review.reject:refund_recorded` | pass | retry after completer: 200 review (replayed) | 4.906 |  |
| 60 | `review.reject:refund_recorded:before_commit` | pass | retry after completer: 200 review (replayed) | 4.278 |  |
| 61 | `review.reject:finished` | pass | retry after completer: 200 review (replayed) | 3.242 |  |
| 62 | `review.reject:finished:before_commit` | pass | retry after completer: 200 review (replayed) | 4.875 |  |
| 63 | `payout.create:started` | pass | retry after completer: 200 in_transit (replayed) | 4.798 |  |
| 64 | `payout.create:started:before_commit` | pass | retry after completer: 200 in_transit | 3.616 |  |
| 65 | `payout.create:balance_reserved` | pass | retry after completer: 200 in_transit (replayed) | 6.305 |  |
| 66 | `payout.create:balance_reserved:before_commit` | pass | retry after completer: 200 in_transit (replayed) | 7.053 |  |
| 67 | `payout.create:bank_requested` | pass | retry after completer: 200 in_transit (replayed) | 14.425 |  |
| 68 | `payout.create:bank_requested:before_commit` | pass | retry after completer: 200 in_transit (replayed) | 6.867 |  |
| 69 | `payout.create:bank_recorded` | pass | retry after completer: 200 in_transit (replayed) | 4.808 |  |
| 70 | `payout.create:bank_recorded:before_commit` | pass | retry after completer: 200 in_transit (replayed) | 5.629 |  |
| 71 | `payout.create:finished` | pass | retry after completer: 200 in_transit (replayed) | 4.869 |  |
| 72 | `payout.create:finished:before_commit` | pass | retry after completer: 200 in_transit (replayed) | 8.682 |  |
| 73 | `payout.cancel:started` | pass | retry after completer: 200 canceled (replayed) | 7.7 |  |
| 74 | `payout.cancel:started:before_commit` | pass | retry after completer: 200 canceled | 7.991 |  |
| 75 | `payout.cancel:finished` | pass | retry after completer: 200 canceled (replayed) | 5.402 |  |
| 76 | `payout.cancel:finished:before_commit` | pass | retry after completer: 200 canceled (replayed) | 6.194 |  |
| 77 | `notification.dispute.closed:notification_fetched` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"2"} | 6.811 |  |
| 78 | `notification.dispute.closed:effects_written` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"2"} | 11.642 |  |
| 79 | `notification.dispute.closed:committed` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"2"} | 10.718 |  |
| 80 | `notification.dispute.opened:notification_fetched` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 7.533 |  |
| 81 | `notification.dispute.opened:effects_written` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 8.761 |  |
| 82 | `notification.dispute.opened:committed` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 6.799 |  |
| 83 | `notification.payout.failed:notification_fetched` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 5.634 |  |
| 84 | `notification.payout.failed:effects_written` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 6.733 |  |
| 85 | `notification.payout.failed:committed` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 7.723 |  |
| 86 | `notification.payout.paid:notification_fetched` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 6.076 |  |
| 87 | `notification.payout.paid:effects_written` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 6.335 |  |
| 88 | `notification.payout.paid:committed` | pass | poll again: {"processed"=>0, "already_processed"=>0, "cursor"=>"1"} | 7.256 |  |
| 89 | `payment_intent.confirm:authorization_requested+acquirer_drop` | pass | retry after completer: 200 succeeded (replayed) | 8.746 |  |
