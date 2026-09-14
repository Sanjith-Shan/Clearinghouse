# PaymentIntent JSON fields came back reordered from jsonb

**What broke.** The first version of the `payment_intents` migration stored `metadata`,
`last_payment_error`, `risk_fields` and `risk` as `jsonb`, and so did `events.data`. jsonb
doesn't keep the text it was given. It stores object keys in its own order (shorter keys
first), so a declined intent's `last_payment_error` went in as `code, decline_code, message`
and came back as `code, message, decline_code`. The API rendered it in that order, which no
longer matched the versioning fixture's key order, and a merchant's `metadata` would have come
back reordered too. Webhook payloads read from `events.data` would have had every object's
keys shuffled relative to the API response for the same object.

**Caught by.** `spec/payments/payment_intent_spec.rb`, "round-trips the
payment_intent_declined fixture through the database unchanged", on its first run.

**Fix.** Those columns are `json`, which keeps the text exactly, and nothing queries inside
them. The code was never committed with jsonb, so the fix is part of the schema commit,
753f0ca (branch `pr/payments-schema`). The webhook work was told before it started reading
`events.data`.
