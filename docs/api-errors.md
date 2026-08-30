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
| `api_error` | 500 | Our bug. The message carries the request id and nothing else |

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
- `card_declined`: the card was declined; see `decline_code`.
- `idempotency_key_reused`: the key was first used with different parameters. Use a new key for a different request.
- `idempotency_key_in_use`: the key's first request is still running. Retry shortly.
- `api_key_missing`: no `Authorization` header.
- `api_key_invalid`: the key does not match any merchant.
- `api_version_invalid`: the `Clearinghouse-Version` header names a version that does not exist.
- `rate_limit`: slow down and retry.
- `payment_blocked`: RiskGate blocked the payment. Retrying the same payment will not help.
