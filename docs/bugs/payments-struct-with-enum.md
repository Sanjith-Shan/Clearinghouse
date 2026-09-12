# Updating a PaymentIntent with T::Struct#with raised KeyError

**What broke.** `PaymentIntents.save!` and the payments services first made changed copies of
an intent with `T::Struct#with`. `with` works by serializing the struct and deserializing a
new one. For a `T::Enum` prop (`status`) that round trip fails: the value it hands back to the
deserializer is the enum object, not its serialized string, so every change to an intent
raised `KeyError: Enum ... Status key not found: #<...Status::Succeeded>`.

**Caught by.** `spec/payments/payment_intent_spec.rb` ("the charge ... reports captures and
refunds after one") on its first run. It was the first test that changed an intent.

**Fix.** `PaymentIntent#copy(**changes)` builds the new struct from the current props plus the
changes, with no serialization, and refuses an unknown field name. The code was never committed
with `with`, so the fix is part of the schema commit, 753f0ca (branch `pr/payments-schema`).
