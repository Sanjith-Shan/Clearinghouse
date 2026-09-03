# API changelog

Generated from the version change modules in `lib/clearinghouse/versioning/changes/` by
`bin/changelog`. Do not edit by hand.

Latest version: `2026-09-01`. A merchant is pinned to the latest version when it is
created. Send `Clearinghouse-Version: <date>` to use another version for one request.

## 2026-09-01

- **payment_intent**: PaymentIntent `payment_method` is now the payment method id (`pm_...`) instead of the embedded PaymentMethod object. Pass `expand[]=payment_method` to get the object.

## 2026-06-01

- **payment_intent**: PaymentIntent `failure_code` and `failure_message` are replaced by a `last_payment_error` object with `code`, `decline_code` and `message`. `decline_code` is new and says why the issuer declined.

## 2026-03-01

- **payment_intent**: PaymentIntent `amount_captured` is renamed to `amount_received`. The value is unchanged: the amount captured so far, in minor units.

## 2026-01-01

The first version of the API.
