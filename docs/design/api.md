# API layer

The HTTP surface of Clearinghouse: a Sinatra app on Puma that speaks JSON, returns
Stripe-shaped errors, and renders every response at the caller's API version. This note
covers the skeleton, errors, ids and logging, and is the guide for adding an endpoint.

## Shape

```
Puma
  RequestLogger (Rack middleware)   gives the request a req_ id, writes one JSON log line
    Api::App (Sinatra::Base)        before filter builds the Context
      Routes::Health, ...           Sinatra extensions registered by the App
```

- `Api.rack_app(deps)` builds the stack. `config.ru` calls it with
  `Dependencies.from_env`; specs and experiments call it with their own.
- **No globals.** `Api::Dependencies` is a `T::Struct` holding the database, the clock,
  the acquirer client, the admin token and the log sink. A test passes a
  `Clock::Test` and a `StringIO` (or nil) log, an experiment can point the app at another
  database, and nothing in the request path reads `ENV` or `Time.now`.
- **One context per request.** `Api::Context` carries the dependencies, the request id,
  method, path and `Idempotency-Key`, and later the merchant and API version. Domain code
  takes a Context, never a Sinatra object, so services can be called from workers and
  tests without HTTP.
- Sinatra's own conveniences that do not fit a JSON API are switched off: Rack::Protection
  (bearer keys, no cookies, so no CSRF or session attacks to defend), `_method` overrides,
  HTML error pages, and host authorization.

## Adding an endpoint (for the payments work)

1. Create `lib/clearinghouse/api/routes/<resource>.rb` as a Sinatra extension:

   ```ruby
   module Clearinghouse::Api::Routes::PaymentIntents
     def self.registered(app)
       app.post '/v1/payment_intents' do
         T.bind(self, Api::App)
         p = api_params.permit!('amount', 'currency', 'payment_method', 'capture_method')
         intent = PaymentIntents.create(ctx, amount: p.integer('amount', required: true, min: 1), ...)
         respond(intent.to_api)
       end
       app.get '/v1/payment_intents/:id' do |id|
         ...
       end
     end
   end
   ```

2. `require_relative` it from `lib/clearinghouse/api.rb` and add `register Routes::PaymentIntents`
   at the bottom of `App`.
3. Raise `Api::Errors::*` for anything the caller did wrong. Anything else becomes a 500
   `api_error` with the details in the log, not the response.

Rules the helpers enforce:

- `api_params` merges the query string and the body. Form-encoded bodies with
  Stripe's bracket nesting (`metadata[order_id]=6735`, `expand[]=payment_method`) and
  JSON bodies parse to the same Hash, because Rack's nested-query parser does the form
  side. Typed readers (`integer`, `string`, `enum`, `boolean`, `metadata`, `expand`)
  coerce form strings and raise a parameter error that names the parameter.
- `permit!` rejects any parameter the endpoint did not list, as `parameter_unknown`
  with `param` set, including nested ones (`shipping[address][town]`). `metadata` takes
  any keys, within Stripe's published limits (50 keys, 40-char keys, 500-char values).
  `expand` is allowed everywhere.
- Route captures come in as block arguments. Sinatra's own `params` is left alone.
- `respond(hash)` is the only way a success body leaves the app.

For idempotency: `ctx.idempotency_key` is the raw header, and `api_params.raw` is the
parsed request, ready to be fingerprinted.

## Errors

`Api::Errors` is one class per error type. Each knows its HTTP status and renders as

```json
{"error": {"type", "code", "decline_code", "param", "message", "doc_url"}}
```

`type`, `code`, `decline_code`, `param` and `message` are always present, null when they
do not apply, so a client can read them without checking for the key. `doc_url` appears
when there is a code and points at `docs/api-errors.md`.

| class | type | status | Should-Retry |
|---|---|---|---|
| `InvalidRequestError` | `invalid_request_error` | 400 | false |
| `NotFoundError` (resource or route) | `invalid_request_error` | 404 | false |
| `CardError` | `card_error` | 402 | false |
| `IdempotencyKeyReusedError` | `idempotency_error` | 400 | false |
| `IdempotencyKeyInUseError` | `idempotency_error` | 409 | true |
| `AuthenticationError` | `authentication_error` | 401 | false |
| `RateLimitError` | `rate_limit_error` | 429 | true |
| `RiskError` (`payment_blocked`) | `risk_error` | 402 | false |
| `ApiError` | `api_error` | 500 | see below |

Unknown routes are the same `invalid_request_error` shape with code `url_invalid`. An
unexpected exception is logged with its class, message, backtrace and request id, and the
caller gets only "An unexpected error occurred while processing your request (req_...)".
A spec raises an exception whose message contains a fake password and checks it does not
appear in the response.

### `Clearinghouse-Should-Retry`

Modelled on `Stripe-Should-Retry`. The header answers one question: *if the client sends
this exact request again, same parameters and same `Idempotency-Key`, can it succeed?* It
is sent only when the answer is known.

- **409 key in use: true.** The first request is still running. A retry either replays its
  stored result or resumes it.
- **429: true.** Rate limits pass.
- **400 fingerprint mismatch, and every other 4xx: false.** The error depends only on the
  request, so the same request fails the same way. That includes card declines: a retry
  under the same key replays the stored decline. A client that wants to try again with
  another card sends a different request.
- **500: true when the retry is safe, otherwise absent.** A 500 can happen after a side
  effect committed (the acquirer charged, the response was lost). A read is always safe to
  repeat. A write that carried an `Idempotency-Key` is safe too, because the retry hits the
  stored response or resumes from the recovery point instead of charging again. A keyless
  POST gets no header, because nobody knows whether the first attempt did anything.

The rule lives in `Errors.retry_header`. The client SDK follows the header when it is
present and falls back to its own policy when it is not.

## Ids

`Ids.generate('pi')` returns `pi_` and 24 characters from `SecureRandom.alphanumeric`,
which draws uniformly from `[A-Za-z0-9]` (no modulo bias), so about 143 bits of
randomness. Prefixes live in one registry (`Ids::PREFIXES`) keyed by object type, and an
unregistered prefix raises, so two object types cannot quietly share one. Ids are opaque
to clients but readable in logs, and the ledger's flow ids are the object ids.

## Request logging

One JSON line per request on stdout: time (from the injected clock, so simulated time in
experiments), method, path, status, `duration_ms`, request id, merchant, API version and
idempotency key when present. Duration comes from the monotonic clock, because it measures
this process, not simulated time. The logger is a Rack middleware outside Sinatra, so
it also logs requests the app rejects before routing. Tests pass `log: nil` and are quiet.
