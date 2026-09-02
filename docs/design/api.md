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
- Every `/v1` route except the admin bootstrap is authenticated in the `before` filter,
  before routing, so no route can forget it. `ctx.merchant!` is the merchant.
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

## API versioning

Built after Brandur Leach, *APIs as infrastructure: future-proofing Stripe with
versioning* (2017), https://stripe.com/blog/api-versioning (reading list item 4). The
ideas taken from it: versions are dates, a caller is pinned to the version current when
it signed up and can override it per request with a header, core code only ever knows the
latest shape, and each backwards-incompatible change is one self-contained module that
declares the resources it touches and knows how to turn the new shape into the old one.
The changelog is generated from those modules.

### Versions

`2026-01-01` (initial), `2026-03-01`, `2026-06-01`, `2026-09-01` (latest). A version
exists because a change shipped on that date. The request's version is the
`Clearinghouse-Version` header if sent, otherwise the merchant's pinned version,
otherwise the latest. An unknown header value is a 400 `api_version_invalid`, not a
silent fallback, because a client that asked for a shape must not get a different one.
Every versioned response says which version it was rendered at in a
`Clearinghouse-Version` response header.

### The pipeline

`Versioning::Engine#render(object, version, expand:, context:)`:

1. Copy the latest-shape object. The caller's hash is never modified.
2. Expand the caller's `expand[]` paths, then every field that a skipped change forces to
   be embedded (below). Expansion works on the latest shape, through one loader per
   `(resource, field)` registered on the `Expander`.
3. Take the changes newer than the requested version, newest first. For each, walk the
   whole tree and transform every object whose `object` is one of the change's resources.
   The walk reaches objects at the top, inside a list's `data`, inside an event's
   `data.object`, and embedded in other objects, so a change is written once per resource,
   not once per place the resource can appear.

`render_event(event, version)` stamps `api_version` on the envelope and renders it the
same way, which is what webhook delivery will call per endpoint version.

The walk skips `metadata`. It is merchant data, and a merchant who stores
`{"object": "payment_intent", "amount_received": "5"}` there must get it back verbatim. A
spec checks exactly that.

### A change module

`VersionChange` is an abstract class. A change overrides `version`, `description`,
`resources` and `transform(hash) -> hash`, and optionally:

- `forced_expansions`: `[resource, field]` pairs that were always embedded before this
  change.
- `request_endpoints` and `transform_request(endpoint, params)`: for a change that renamed
  a request parameter. Old callers still send the old name, and the engine rewrites their
  parameters into the latest shape, oldest change first, before the endpoint reads them.
  An endpoint opts in by reading `versioned_params('payment_intents.capture')` instead of
  `api_params`. None of the three shipped changes renames a request parameter, so this
  hook is exercised by specs with test-only changes.
- `side_effects?`: Stripe's `has_side_effects`, for a change whose old behaviour is logic,
  not shape. Its transform is the identity and the code that differs asks
  `engine.legacy?(ThatChange, ctx.api_version)`.

Stripe's modules use a small DSL. These are plain method overrides, so Sorbet checks each
one against the abstract interface.

### The three changes

| version | change | kind |
|---|---|---|
| `2026-03-01` | `amount_captured` renamed to `amount_received` | rename |
| `2026-06-01` | flat `failure_code` + `failure_message` became a `last_payment_error` object with `code`, `decline_code`, `message` | two fields into one object (going back: one object into two fields) |
| `2026-09-01` | `payment_method` became an expandable id; before, it was always the embedded PaymentMethod | nested object to expandable id |

The rename keeps the key's position so old responses read the same as before. Going back
across 2026-06-01 drops `decline_code`, because old clients never received it.

**How the 2026-09-01 transform gets the object it needs.** At the latest version the
renderer has only `"pm_card_visa"`. Three options:

1. Give transforms a loader or database handle. Transforms stop being pure functions of
   their input, and a list of 100 intents becomes 100 lookups inside the walk.
2. Make the latest representation carry enough to rebuild the old object. That leaks
   old-version data into every new response, which defeats the change.
3. **Expand before transforming** (chosen). The change declares
   `forced_expansions: [["payment_intent", "payment_method"]]`. For callers older than
   2026-09-01 the engine expands that field through the same loader that serves
   `expand[]=payment_method`, before any transform runs. The transform itself is only a
   guard that raises if it ever sees a bare id.

So expansion has one code path whether the caller asked for it or an old version requires
it, and transforms stay pure. The cost is that an old caller always pays for the lookup,
which is what an embedded field always cost them anyway. Payment methods here are the
fixed test tokens (`Clearinghouse::PaymentMethods`), so this loader does no I/O; the
payments work registers loaders for `latest_charge` and friends in
`Versioning.default_expander`, with the request Context as the loader's `context`.

Expansion paths are resolved against the latest shape. None of the shipped changes renames
an expandable field, so there is no ambiguity yet; a change that did would need to map the
old path.

### Fields no change may touch

RiskGate reads webhooks at whatever version its endpoint is pinned to, and its contract
names `id`, `amount`, `currency`, `payment_intent`, `reason` and `status` as stable. The
engine enforces this instead of trusting each change: after every transform it compares
those keys (plus `object`, which the walk depends on) before and after, and raises
`ProtectedFieldError` on any difference, including a dropped key. A spec also renders
every fixture at every version and checks every protected value at every path.

### Golden files

`spec/fixtures/resources/` holds latest-version JSON for a succeeded PaymentIntent, a
declined one, a list of both, and a `payment_intent.succeeded` event wrapping the first.
`spec/versioning/golden_spec.rb` renders each at every version and compares the pretty
JSON byte for byte with `spec/fixtures/golden/<version>/<name>.json`, so a change to any
transform shows up as a readable diff in review. `UPDATE_GOLDEN=1 bundle exec rspec
spec/versioning/golden_spec.rb` rewrites them. The spec also fails on golden files for a
version or fixture that no longer exists, and checks that the list and event fixtures
embed exactly the standalone PaymentIntent fixtures.

The PaymentIntent fixture is the contract with the payments work: it is the latest shape
their serializer must produce.

### Adding a change

1. Write a class under `lib/clearinghouse/versioning/changes/` and add it to
   `Versioning.registry`.
2. Update the latest fixtures to the new shape, then `UPDATE_GOLDEN=1` and read the diff:
   every older golden file should be unchanged.
3. Run `bin/changelog` to regenerate `docs/api-changelog.md`. A spec fails if it is stale.

## Merchants and authentication

`merchants (id acct_..., name, secret_key_hash, secret_key_last4, api_version,
fee_rate_scaled, fee_fixed_minor jsonb, payout_interval, payout_delay_days, created_at)`,
with check constraints on every format and range. The app role gets `SELECT, INSERT` and
nothing else; a spec proves `UPDATE` and `DELETE` are refused. `created_at` comes from the
injected clock, never a database default, so simulated time is consistent.

### Secret keys

`sk_test_` plus 24 base62 characters from SecureRandom, about 143 bits. The plaintext is
returned once, in the `POST /v1/merchants` response, and only its SHA-256 hex digest is
stored.

**Why SHA-256 and not bcrypt.** A slow password hash makes each guess expensive, which
matters when the secret is a human-chosen password that can be guessed in 2^30 tries.
Nobody guesses a 143-bit random key at any hash speed, so the slowness buys nothing. It
would cost a deliberately slow hash (tens of milliseconds or more, by design) on every API
request, and bcrypt's per-row salt would make lookup by digest impossible: authenticating
would mean trying every merchant's hash.

**Lookup and timing.** The key is checked against its expected shape first, so garbage
never reaches the database. Then the lookup is by digest through the unique index. Its
timing depends on the digest of the caller's guess, not on any stored secret, and learning
that SHA-256(guess) shares a prefix with a stored digest does not help anyone find a
preimage. The one comparison between a stored value and a caller-derived value is
`Rack::Utils.secure_compare` anyway, so it never short-circuits.

Keys arrive as `Authorization: Bearer sk_test_...`, or as HTTP Basic with the key as the
username (`curl -u sk_test_...:`), both as in Stripe's API. Errors say `api_key_missing`
or `api_key_invalid`, and show only `sk_test_****` plus the last four characters.

### Version pinning

A merchant's `api_version` is set at creation to the latest version (or to an older one
passed as `api_version`, which the demos and golden tests use), and every request it makes
renders at that version unless it sends `Clearinghouse-Version`. There is no upgrade
endpoint yet; it would be a one-row update and the reason `UPDATE` is not granted today is
that nothing needs it.

### The admin bootstrap

`POST /v1/merchants` has no Stripe equivalent: Stripe onboards merchants through its
dashboard. Clearinghouse is a simulation with no dashboard, so demos, experiments and
RiskGate's replay driver create merchants over the API. The endpoint is guarded by
`CLEARINGHOUSE_ADMIN_TOKEN` as a Bearer token, compared in constant time after hashing
both sides (so the token's length does not leak either). With no token configured the
endpoint refuses every call. A merchant secret key is not accepted in its place.

`GET /v1/account` returns the authenticated merchant, as Stripe's does.

## Handoff to the payments work

- **The PaymentIntent JSON** in `spec/fixtures/resources/payment_intent.json` is the latest
  shape. Serialize to exactly that and the three version changes and the golden files
  apply unchanged. If the shape has to change, change the fixture, rerun
  `UPDATE_GOLDEN=1`, and check the diff touches only the latest version's files unless a
  version change is intended.
- **Expanders.** Register loaders for `latest_charge` and any other expandable field in
  `Versioning.default_expander`. The loader's `context` is the request `Context`.
- **Idempotency.** `ctx.idempotency_key` is the header; fingerprint `api_params.raw`
  (what the client sent, before any request-side version transform). Raise
  `IdempotencyKeyReusedError` and `IdempotencyKeyInUseError` and the status codes and
  `Clearinghouse-Should-Retry` values follow.
- **Collaborators** (acquirer client, RiskGate client, crash hook) are new props on
  `Api::Dependencies`. `acquirer` is typed `T.nilable(Object)` until its client exists.
- **Balance.** `GET /v1/balance` does not exist yet; it belongs with the ledger reads.
- **Specs** get the app from `include_context 'with the api app'` and a merchant with
  headers from `include_context 'with a merchant'` (`auth`), both in
  `spec/support/api_helpers.rb`. Once the ledger's `DBHelper` is merged, merchant
  cleanup can move into its `clean_tables` list.
- **Events.** `Versioning.render_event(event_hash, endpoint_version)` renders a webhook
  payload at the endpoint's version.
