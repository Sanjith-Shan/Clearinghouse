# Posting crashed on every call: `Hash.new(0)` ignored by `fetch`

**What broke.** `Ledger::Posting#validate!` accumulated per-currency nets in a hash built with
`Hash.new(0)` and read it back with `nets.fetch(currency)`, and `apply_balances` did the same
for per-account deltas. `Hash#fetch` ignores a hash's default value, so the first entry in any
posting raised `KeyError`. I'd reached for `fetch` because Sorbet types `hash[key]` as
nilable and `fetch` as the value type, and I didn't notice that it drops the default.

**Caught by.** The first run of `spec/ledger/posting_spec.rb`: 20 examples failed with
`KeyError: key not found: "platform:processor_receivable"`.

**Fix.** Plain `{}` hashes read with `fetch(key, 0)`, which Sorbet types as `Integer` and which
states the default where it's used. The code had never been committed in the broken state,
so the fix is part of the posting commit, a7e2b43 (branch `pr/ledger-posting`).
