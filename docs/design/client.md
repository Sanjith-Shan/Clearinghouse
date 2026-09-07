# clearinghouse-ruby: a client that retries safely

`clients/ruby/` is a small Ruby client library for the Clearinghouse API, shaped as its own
gem (`clearinghouse_client.gemspec`) and depending on nothing outside the standard library
(`net/http`, `json`, `securerandom`, `openssl`). Its specs live in `spec/clients/ruby/` so
the root suite runs them.

The server does half of the idempotency work: it stores a result per `Idempotency-Key` and
replays it. This library is the other half. A server-side idempotency layer is worth nothing
if the client that retries sends a new key each time.

## Sources

- Stripe, *Designing robust and predictable APIs with idempotency* (2017),
  https://stripe.com/blog/idempotency (reading list item 2). The two sentences this library
  is built on: "a client generates a unique ID to identify just that operation and sends it
  up to the server along with the normal payload", and "If the client notices a failure, it
  retries the request with the same ID". The same post describes backoff proportional to
  `2^n` and adding random jitter "to space out requests across all clients", and says
  Stripe's Ruby library "retries on failure automatically with an idempotency key using
  increasing backoff times and jitter".
- The `stripe-ruby` README, https://github.com/stripe/stripe-ruby, section on automatic
  retries: retries are opt-in through `max_network_retries`, "Various errors can trigger a
  retry, like a connection error or a timeout, and also certain API responses like HTTP
  status `409 Conflict`", and "Idempotency keys are added to requests to guarantee that
  retries are safe."
- `docs/design/api.md` in this repo, for how the server sets `Clearinghouse-Should-Retry`
  (modelled on `Stripe-Should-Retry`) and which error types exist.

## One key per logical call

```ruby
client = ClearinghouseClient::Client.new(api_key: 'sk_test_...', base_url: 'http://127.0.0.1:4000')
response = client.request(:post, '/v1/payment_intents', params: { amount: 2000, currency: 'usd' })
```

`Client#request` generates the `Idempotency-Key` (a UUID v4) **once, before the first
attempt**, and sends that same key on every retry of the call. That one line is what makes
retrying a charge safe. Walk through the cases a retry can land in:

| What happened to the attempt that failed | What the retry with the same key gets |
|---|---|
| Never reached the server (connection refused, DNS failure) | The server runs the request for the first time |
| Reached the server and finished, but the response was lost (dropped connection, read timeout) | The stored result, byte for byte, with `Idempotent-Replayed: true`. No second charge |
| Reached the server and is still running | `409 idempotency_key_in_use` with `Clearinghouse-Should-Retry: true`. The client waits and asks again |
| Reached the server and failed deterministically (a decline, a bad parameter) | The stored failure again. The client does not retry these in the first place |

With a new key per attempt, row two becomes a double charge. The spec
`spec/clients/ruby/client_spec.rb` asserts the reuse directly: every retry scenario checks
that all attempts the fake server saw carried one key. Moving key generation inside the
retry loop makes four of those specs fail, which I checked by doing exactly that.

A caller can pass `idempotency_key:` to use its own. That matters when the retry comes from
somewhere other than this loop, like a job that crashed and ran again: the library's key
dies with the process, a key derived from the caller's own order id does not. POST and
DELETE get keys, GET never does (a key on a GET is an `ArgumentError`, because it would do
nothing and suggest otherwise).

## When to retry

`RetryPolicy#retry?` decides, in this order:

1. The budget: `max_network_retries` (default 2, so at most 3 attempts). Zero turns retries
   off entirely.
2. **No response at all** (connection refused, dropped, timed out): retry. For a mutating
   call this is safe *because* the key is reused; for a GET it is safe anyway.
3. A `Retry-After` longer than 60 seconds: stop and raise. Retrying before the server said
   to would be rude, and blocking a caller for minutes inside one method call is worse than
   handing the error back.
4. **The server's `Clearinghouse-Should-Retry` header**, when present, decides. The server
   knows things the status cannot say: whether a 500 happened after a side effect, whether
   a 409's first request is still running. It overrides the heuristic in both directions,
   so a 500 marked `false` is raised at once and a 4xx marked `true` is retried.
5. Otherwise the status: retry 409, 429 and 5xx, never any other 4xx. A 400 is a property
   of the request, and sending the same request again gets the same answer.

`Net::HTTP` retries GET and DELETE once by itself on some connection errors. The client
sets `max_retries = 0` so every attempt goes through the policy and is counted and backed
off. A spec proves a dropped GET and DELETE reach the server exactly once with retries off.

### Backoff

Retry `n` (from 1) sleeps a uniform draw from `[0, min(8s, 0.5s * 2^(n-1)))`: exponential
backoff with **full jitter** and a cap. Full jitter rather than "base plus a little noise"
because the case backoff is for is a crowd: a hundred clients whose requests failed in the
same second. Drawing across the whole window spreads their retries over it instead of
sending them back together a fixed time later. A `Retry-After` is a floor on the sleep.

The sleeper and the RNG are constructor arguments, so specs record the exact sleeps
(`[0.25, 0.5]` for two retries at a fixed draw of 0.5) without sleeping.

### Connection errors and what was sent

`APIConnectionError#maybe_processed?` is false when the connection never opened (nothing
was sent) and true when it failed after opening (the server may have done the work). The
client opens the connection and sends the request as two separate steps so it can tell
them apart, the same approach as the acquirer client (`docs/design/sim.md`). The retry
decision doesn't depend on it, since both are safe with a reused key, but a person reading
an error after all retries failed needs to know whether to go and check.

## Resource helpers

Thin methods over `request` that return the parsed body as a plain Hash:

```ruby
intent = client.payment_intents.create(amount: 2000, currency: 'usd', payment_method: 'pm_card_visa')
client.payment_intents.confirm(intent['id'])
client.payment_intents.capture(intent['id'], { amount_to_capture: 1500 }, idempotency_key: "capture-#{order.id}")
client.refunds.create(payment_intent: intent['id'], amount: 500)
client.balance.retrieve
client.webhook_endpoints.delete('we_...')
```

Covered: `payment_intents.create/retrieve/confirm/capture/cancel/list`, `refunds.create/retrieve`,
`payouts.create/retrieve`, `webhook_endpoints.create/list/delete`, `balance.retrieve`,
`account.retrieve` and `events.list`. Plain hashes rather than resource objects because
the objects would be a second copy of the API's shape to keep in step, and the server
already renders the caller's API version; a Hash is exactly what the caller asked for.

Parameters are a Hash, keywords, or both (keys are normalised to strings and the keyword
wins a clash, so the same parameter is never sent twice). `idempotency_key:` and
`api_version:` are options, not parameters. Ids are checked (an empty id would turn
`retrieve('')` into a request for the collection) and percent-encoded, so `pi_1/../x`
stays one path segment.

POST bodies are JSON. The server accepts JSON and form bodies alike (`Api::Params`), and
JSON keeps integers as integers and needs no encoder for nesting. Query strings for GET
use the bracket style the server's form parser reads (`expand[]=...`, `created[gte]=...`).

### Auto-pagination

`client.payment_intents.each(limit: 100) { |intent| ... }` (also on `webhook_endpoints`
and `events`) walks every page, sending the last id of each page as `starting_after`
until `has_more` is false. Without a block it returns a lazy Enumerator, so
`.each.first(2)` makes one request. Starting with `ending_before` pages backwards using
each page's first id. A page with no data ends the walk even if it claims `has_more`,
so a server bug cannot loop the client forever. Each page is an ordinary GET, so it gets
the retry policy too.

## Webhook verification

```ruby
event = ClearinghouseClient::Webhook.construct_event(raw_body, signature_header, secret, tolerance: 300)
```

The library carries its own copy of the verifier, because a client library cannot depend
on server code. Its rules are the server's (`lib/clearinghouse/webhooks/signature.rb`,
explained in `docs/design/webhook-security.md`): exactly one `t` of 1 to 15 digits, at least
one non-empty `v1`, unknown schemes ignored, empty elements malformed, signature checked
before timestamp, inclusive tolerance, constant-time compare. `secret` can be an Array
during a rotation. Failures raise `SignatureVerificationError` whose `code` is spelled as
in the vectors. A body that verifies but is not a JSON object raises
`InvalidPayloadError`.

Two copies of a parser can drift, so two specs hold them together:

- every vector in `spec/fixtures/signatures.json` runs against the client copy, and
- a differential spec builds 3000 headers from the grammar's own pieces (`t=`, `v1=`,
  commas, tabs, a good signature, an uppercased one, a stale timestamp) and checks that the
  client and server verifiers return the same outcome for each one.

## Errors

A non-2xx response becomes an exception chosen by the body's `error.type`:

| type | class | extra |
|---|---|---|
| `card_error` | `CardError` | `decline_code` |
| `invalid_request_error` | `InvalidRequestError` | `param` |
| `idempotency_error` | `IdempotencyError` | |
| `authentication_error` | `AuthenticationError` | |
| `rate_limit_error` | `RateLimitError` | |
| `risk_error` | `RiskError` | |
| `api_error` | `APIError` | |
| (no response) | `APIConnectionError` | `maybe_processed?` |

Every one carries `http_status`, `request_id` (from the `Request-Id` header, the thing to
quote in a support ticket), `code`, `http_headers` and `error`, the raw error hash. A body
that isn't an API error (an HTML 502 from a proxy) falls back on the status code, ending at
`APIError`.

`Response` exposes `data` (the parsed body), `request_id`, `idempotent_replayed?` and
`attempts`, the number of HTTP attempts the call took.

## Standard library only, with Sorbet sigs

A client library that makes its users install `sorbet-runtime` is a worse library, but this
repo type-checks everything, so the code carries sigs. `sorbet_stub.rb` resolves that: if
`T::Sig` is not already defined, it defines `sig` as a no-op that never evaluates its block.
Inside this repo sorbet-runtime is loaded first, so the sigs are enforced at runtime in the
specs, and `srb tc` checks the library like any other file. Outside, nothing but the
standard library loads. A spec starts a bare `ruby --disable-gems` with only the library
on the load path and checks that it loads and builds a client.

## Tests

- `retry_policy_spec.rb`: the decision table and backoff arithmetic, with no I/O.
- `client_spec.rb`: a scripted HTTP server on a real socket (`spec/support/scripted_api_server.rb`)
  that drops connections, hangs past the read timeout, returns 409 then 200, 500 with
  `Should-Retry: false`, 429 with `Retry-After`, 400, and HTML. Each spec asserts the number
  of attempts the server saw, that they carried one key, the sleeps, and the error type.
- `api_integration_spec.rb`: the real `Api::App` on Puma on a random port. It creates a
  merchant with a JSON body, authenticates as it, checks `Clearinghouse-Version` from the pin,
  the client and the call, and maps real 401 and 400 responses. Payment endpoints are not
  merged yet, so their helpers are tested against the scripted server until they are.
- `resources_spec.rb`: every helper's method, path, body and key header; pagination
  following `starting_after`, laziness, backwards paging and the empty-page stop.
- `webhook_spec.rb`: the shared vectors, the differential check against the server
  verifier, and `construct_event`.

## Not done

- Connection reuse. Each attempt opens its own connection, which keeps the client free of
  shared state (one instance is safe across threads) at the cost of a handshake per call.
- Telemetry. Stripe's libraries report the previous request's latency on the next one;
  nothing here needs it.
