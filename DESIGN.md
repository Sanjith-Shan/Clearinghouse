# Clearinghouse design

Written for a reader who has never seen the repo. Each area has its own note under
`docs/design/`, and this file ties them together.

## Reading list

The design is built from public engineering writing, credited here.

1. Brandur Leach, *Implementing Stripe-like Idempotency Keys in Postgres* (2017), https://brandur.org/idempotency-keys
2. Stripe, *Designing robust and predictable APIs with idempotency* (2017), https://stripe.com/blog/idempotency
3. Ilya Ganelin, *Ledger: Stripe's system for tracking and validating money movement* (2024), https://stripe.dev/blog/ledger-stripe-system-for-tracking-and-validating-money-movement
4. Brandur Leach, *APIs as infrastructure: future-proofing Stripe with versioning* (2017), https://stripe.com/blog/api-versioning
5. Stripe docs on webhook signatures, https://docs.stripe.com/webhooks
6. `stripe/smokescreen`, https://github.com/stripe/smokescreen
7. Stripe docs on test clocks, https://docs.stripe.com/billing/testing/test-clocks

## Money and time

- Amounts are integer minor units with an ISO 4217 exponent table (`lib/clearinghouse/currency.rb`).
  JPY and KRW have no minor unit, KWD and BHD have three. Parsing a fraction the currency
  cannot hold is an error, never a silent round.
- Fees are percentage plus fixed, computed in integers and rounded half-even. Net is defined
  as gross minus fee, so gross equals net plus fee by construction, and a property test
  checks it anyway along with the rounding bound.
- Every component reads a `Clearinghouse::Clock`. Tests use a test clock that only moves
  when told to and never moves backwards.

## Areas

- [Internal interfaces](docs/design/interfaces.md): the contracts between the parts.
- [Ledger](docs/design/ledger.md): accounts, the money-flow table, policy choices, and how the database enforces double entry and append-only.
- [API](docs/design/api.md): request handling, errors, auth, and date-based versioning. The changelog is generated into [docs/api-changelog.md](docs/api-changelog.md).
- [Webhook security](docs/design/webhook-security.md): signatures, secret rotation, test vectors shared with the Go verifier, and the SSRF-safe egress path.

## Bugs the harness caught

See `docs/bugs/`.
