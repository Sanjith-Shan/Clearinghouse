# API errors

Every error is a JSON body of this shape, with the HTTP status of its type:

```json
{"error": {"type": "card_error", "code": "card_declined", "decline_code": "insufficient_funds",
           "param": "payment_method", "message": "Your card has insufficient funds.",
           "doc_url": "https://github.com/Sanjith-Shan/Clearinghouse/blob/main/docs/api-errors.md#card_declined"}}
```

`type`, `code`, `decline_code`, `param` and `message` are always present (null when they do
not apply). `doc_url` is present when `code` is, and points at the entry below.

## Types

| type | status | meaning |
|---|---|---|
| `invalid_request_error` | 400, 404 | The request is wrong: a parameter, a missing object, a state that does not allow the action |
| `card_error` | 402 | The acquirer declined the card. `decline_code` says why |
| `idempotency_error` | 400, 409 | An `Idempotency-Key` was reused with different parameters (400) or while its first request is still running (409) |
| `authentication_error` | 401 | No API key, or a key that does not exist |
| `rate_limit_error` | 429 | Too many requests |
| `risk_error` | 402 | RiskGate blocked the payment |
| `api_error` | 500, 503 | 500: our bug; the message carries the request id and nothing else. 503: the card network did not answer (`acquirer_unavailable`) |

## Retrying

Error responses carry `Clearinghouse-Should-Retry: true` or `false` when it is known whether
sending the *same* request again (same parameters, same `Idempotency-Key`) can succeed. The
header is absent when that is not known. See `docs/design/api.md`.

## Codes

- `parameter_missing`: a required parameter was not sent. `param` names it.
- `parameter_unknown`: a parameter the endpoint does not accept. `param` names it, with brackets for nested ones.
- `parameter_invalid`: a parameter has the wrong type or an out-of-range value.
- `body_invalid`: the body is not valid JSON, not a JSON object, not a supported content type, or has conflicting form nesting.
- `resource_missing`: no object with that id exists for this merchant.
- `url_invalid`: no such route.
- `card_declined`: the card was declined; see `decline_code` (`generic_decline`, `insufficient_funds`).
- `expired_card`: the card has expired. `decline_code` is `expired_card` too.
- `payment_intent_unexpected_state`: the PaymentIntent's status does not allow this request (capturing one that is not `requires_capture`, confirming one that already succeeded). The message lists the statuses that would have worked.
- `payment_intent_authorization_expired`: the authorization waited longer than the capture window and can no longer be captured. The expiry sweep cancels it.
- `amount_too_small`: the amount (or `amount_to_capture`) does not cover the processing fee.
- `capture_failed`: the card network refused the capture. The PaymentIntent is unchanged.
- `acquirer_unavailable` (503): the card network did not answer, so the outcome is not known yet. Nothing has failed. Retry with the same `Idempotency-Key` and the request resumes where it stopped.
- `idempotency_key_reused`: the key was first used with different parameters. Use a new key for a different request.
- `idempotency_key_in_use`: the key's first request is still running. Retry shortly.
- `idempotency_key_invalid`: the `Idempotency-Key` header is empty or longer than 255 characters.
- `lock_timeout` (409): another request is changing this PaymentIntent right now (a capture while a cancel is in flight). Retry shortly.
- `api_key_missing`: no `Authorization` header.
- `api_key_invalid`: the key does not match any merchant.
- `admin_token_invalid`: `POST /v1/merchants` needs the admin token, or merchant creation is disabled.
- `api_version_invalid`: the `Clearinghouse-Version` header names a version that does not exist.
- `rate_limit`: slow down and retry.
- `payment_blocked`: RiskGate blocked the payment. Retrying the same payment will not help.
- `balance_insufficient`: the available balance cannot cover the payout: it is lower than `amount`, or zero or negative (payouts are blocked while a negative balance is being paid down). `param` is `amount`.
- `payout_not_cancelable`: the payout has been sent to the bank or has finished. Only a pending payout that has not been sent can be canceled.
- `review_closed`: the review has already been approved or rejected.
- `dispute_already_closed`: the dispute was already won, so there is no loss to accept.
