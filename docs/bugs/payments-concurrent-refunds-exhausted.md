# Concurrent refunds of one payment ran out of serialization retries (500)

**What broke.** Every refund writes its PaymentIntent's `amount_refunded` twice: when it
reserves its amount and when it records the acquirer's answer. Both are SERIALIZABLE phases
that lock the intent with `SELECT ... FOR UPDATE`. Under SERIALIZABLE that lock queues the
writers but does not stop them aborting: a waiter's snapshot predates the winner's commit, so
it gets 40001 when the lock is granted (`docs/design/isolation.md`), and the next winner does
the same to it again. With enough refunds at once, the last in line lost all 8 attempts, and
`Idempotency::Serializable::ExhaustedError` reached the API's generic handler as a 500.

**Caught by.** `spec/api/refunds_spec.rb`, "never refunds more than was captured under
concurrent refunds" (10 refunds), which the model-testing work saw return
`{200=>5, 500=>2, 400=>3}` twice on the loaded machine. I reproduced it on main with 16
refunds of 100 on a 1,600 payment: five runs gave 5 to 10 responses of 500 each, all
`ExhaustedError`, with 157 to 174 serialization retries per run.

**Fix.** Commit 97d8424 (branch `pr/integrate-fix-main`). The refund phases that write the
intent pass an advisory-lock turnstile on it *before* their transactions begin
(`Idempotency::Turnstile`, `Phase#queue_on`), so each starts after the previous one
committed. The same five runs then gave 16 of 200 each, with 40 to 52 retries per run, all
from SSI conflicts between concurrent inserts of different idempotency keys. Running out of
retries anywhere is now a retryable `409 lock_timeout` rather than a 500. The spec now runs
16 refunds and checks every client ends with its refund and never sees a 500.
