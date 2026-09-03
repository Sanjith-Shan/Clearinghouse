# A validation rule that would have rejected valid settlement batches

**What broke.** I first read the spec's "reject mixed currency within one account" as "reject a
transaction that uses one account code in two currencies", and `Ledger::Posting` refused such
postings with `InvalidPostingError`. Accounts are keyed by code and currency, though, so
`platform:cash` in USD and `platform:cash` in JPY are two different accounts. A settlement
batch that books USD and JPY cash in one transaction is valid, and the rule would have made
the reconciler post one transaction per currency for no reason.

**Caught by.** `spec/ledger/posting_spec.rb`, "keeps each currency in its own accounts", which
posts a balanced JPY and KWD transaction to the same codes. It failed against the rule on the
first run.

**Fix.** I dropped the Ruby rule. The real invariant (an entry's currency equals its account's
currency) holds by construction in the API and is enforced for raw SQL by the composite
foreign key on `ledger_entries (account_id, currency)`, tested in
`spec/db/ledger_schema_spec.rb`. The rule was never committed; the corrected code is in
a7e2b43 (branch `pr/ledger-posting`).
