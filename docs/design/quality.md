# Code quality, measured (experiment 7)

Coverage says a line ran. Mutation testing says a test would notice if the line
changed. This note covers how both are measured here, the gates that hold later code
to them, and every surviving mutant that was not killed, with the reason.

The numbers live in `results/exp7-quality/`, produced by one command,
`bin/quality-report`.

## Mutation testing with mutant

`bin/mutation` runs [mutant](https://github.com/mbj/mutant) 0.17 with
`--usage opensource` over the subjects in `.mutant.yml`:

- the money core: `Clearinghouse::Money`, `Currency`, `FeeSchedule`
- the ledger: everything under `Clearinghouse::Ledger`
- webhook signatures: `Clearinghouse::Webhooks::Signature`
- the SSRF address policy: `Clearinghouse::Webhooks::Egress::IpPolicy` and `Target`

Payments and idempotency are left out for now because they are still changing; adding
them is one line each in `.mutant.yml`. `SafeHttp` is left out because its specs are
real sockets and timeouts, so most of its mutants would be decided by the clock.

`bin/mutation --since main` only mutates subjects whose source changed since `main`.
CI runs that on every pull request (`.github/workflows/ci.yml`, 4 jobs). It is not in
`bin/ci` because a full run takes tens of minutes on this laptop.

### One database per mutant job

Mutant forks a worker per job and runs each mutation's selected tests inside it. The
ledger specs truncate and write the ledger tables, so two workers sharing a database
would delete each other's rows mid-example, and a mutation could look killed because
another job's `TRUNCATE` broke the test. Running with `--jobs 1` avoids that but makes a
full run many times slower.

Mutant has a hook for this: `mutation_worker_process_start` runs inside each forked
worker with the worker's index. `spec/mutant_hooks.rb` sets `CLEARINGHOUSE_DB` to
`<base>_<index>` there, and `bin/mutation` creates and migrates `<base>_0` up to
`<base>_<jobs-1>` before starting mutant (locally `clearinghouse_test_mutation_0..`).
The spec helper opens connections lazily, on the first `:db` example, so the name is
set before any connection exists. `bin/mutation` only ever creates and migrates these
databases; it never drops one.

The default is 1 job because this laptop is shared with other work. On a quiet
machine `MUTANT_JOBS=12 bin/mutation`.

### A macOS fork trap that made mutants look alive

The first full run reported 38% coverage. Almost every "alive" mutation had actually
crashed: the kill fork died with `objc[...]: +[NSCharacterSet initialize] may have
been in progress in another thread when fork() was called`, and mutant reported the
integration error as a survivor. libpq tries GSSAPI encryption on a new connection,
which loads the Kerberos framework, which initialises Objective-C classes, which macOS
forbids in a forked child. The database is local and never uses GSSAPI, so
`bin/mutation` sets `PGGSSENCMODE=disable`. With only that change the `Ledger::Checker` subjects went
from all crashing to 96% killed. `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` was not
needed; I checked by setting it to `NO` explicitly.

### Which tests run for which subject

Mutant picks tests by name: a subject `Clearinghouse::Ledger::Posting#post` runs the
examples whose top-level `describe` names it, or the nearest enclosing namespace that
has any. Three places needed help:

- `Currency` had no spec of its own, so its mutants fell back to every example under
  `Clearinghouse`, most of the suite. It now has `spec/unit/currency_spec.rb`.
- `Posting` is exercised through `Clearinghouse::Ledger.post!`, so `posting_spec.rb`
  says so with `mutant_expression` metadata, naming Posting and each facade method.
  Without it, Posting's mutants ran all 93 ledger examples, including the property
  tests, and timed out on a busy machine.
- The `ExplainPrinter` examples are nested inside the `Explain` spec, so they carry
  their own tag, and the `Explain` spec names `Ledger.explain` as well.

### Timeouts count as alive

Mutant's default counts a mutation whose tests time out as killed. That is right for a
mutation that makes a loop spin forever, and wrong when the machine is just busy: the
second full run credited 178 "kills" to timeouts, most of them `ExplainPrinter`
mutations whose selected tests were simply slow. `.mutant.yml` sets
`coverage_criteria.timeout: false` and a 60 second limit, so a timeout shows up as a
survivor and gets looked at.

### Not mutated

`IpPolicy.range` is in the matcher's `ignore` list. It is only called while
`ip_policy.rb` loads, to build the range constants, and mutant inserts a mutation after
the file has loaded, so no test can observe one. The constants it builds are checked
range by range in `ip_policy_spec.rb`.

## Survivors

Every survivor of a run is either killed by a new test or listed below as equivalent.
The tests added for survivors are in `spec/unit/money_spec.rb`, `currency_spec.rb`,
`fees_spec.rb`, `webhooks/signature_spec.rb`, `webhooks/egress/target_spec.rb` and the
ledger specs. A few that are worth a sentence:

- Error messages. Many survivors replaced a message with `nil` or dropped the
  `inspect` that quotes the input. The specs now pin the messages of errors a
  caller or an operator reads (`not a decimal amount: "1e3"`, `usd vs eur`,
  `unknown ledger account code ""`, each SSRF refusal's detail). Quoting matters: an
  empty or space-padded code is invisible without it.
- `Money#==` survived with `return true` for non-Money arguments, and `Money#hash`
  survived as `[].hash`: no spec compared Money with an Integer or checked that
  distinct values hash apart.
- `Clearing.report` survived without its `sort`. That looked redundant, since the SQL
  orders by flow id, but the database collation is `en_US.utf8`, which sorts `pi_a`
  before `pi_B`, and Ruby's byte order does not. The report now has a spec that it lists
  flows in byte order whatever the collation says. It also survived `floor` becoming
  `ceil` on a flow's age, so a spec pins that a flow is not overdue until a whole second
  past its SLA.
- `Signature.compute` survived dropping `.b` on the payload for UTF-8 input, because an
  ASCII-compatible encoding gives the same bytes. A UTF-16 payload does not, and kills it.
- `Target.host_check` survived a split limit of 167: a host with more labels than that
  was not tested. It is now, with 200 labels.
- `Posting#entries_of` survived losing `where(transaction_id:)`: every reversal spec
  reversed the only transaction in the database, so "mirror every entry in the ledger"
  looked the same as "mirror this transaction". A spec now reverses the second
  transaction of a flow.
- `Posting#balance` survived losing `where(account_id:)` on the locked read, and
  `check_flow_type!` survived losing `where(flow_id:)`, for the same reason: each spec
  had one account or one flow. `ensure_accounts` survived `next` becoming `break`,
  because no spec posted a new account next to an existing one that sorts first.
- The branch in `ensure_accounts` for an account another session created first had no
  test at all (it was also the one uncovered ledger branch). A spec now makes that race
  happen deterministically: a second connection inserts the account and holds its
  transaction open, the posting blocks on the unique index, and the spec commits the
  other side once `pg_stat_activity` shows the posting waiting.
- `ExplainPrinter` had many survivors because its specs compared plain text only for a
  single clearing account. The new specs cover several clearing accounts with one back
  at zero, the colors of every styled cell, the defaults, and UTC for a Time in another
  zone.

None of the survivors was a bug in lib code, so there is no entry in `docs/bugs/` from
this work. The closest was the collation-dependent order, which the Ruby `sort` already
handled; the spec now proves it.

## Equivalent mutants

A survivor listed here cannot change behaviour. The list is
`docs/design/quality_equivalents.yml`; `bin/quality-report` regenerates this table
from it and counts a survivor as equivalent only if its diff matches an entry exactly,
so the table cannot drift from the numbers. Recurring reasons are abbreviated:
**[index]** `a[i]`, `a.at(i)` and `a.fetch(i)` only differ out of range, and the array
is a fixed-shape tuple; **[sorbet]** `T.let`/`T.must`/generic type arguments only matter
to the static checker, and sorbet-runtime erases generic element types; **[subclass]**
`is_a?` and `instance_of?` only differ for a subclass, and there is none; **[pg-int]**
Sequel's pg adapter already returns integer columns as Integer, so `Integer()` around
them is a no-op on this adapter.

<!-- equivalents:start -->
| Subject | Mutation | Why it is equivalent |
|---|---|---|
| `Clearinghouse::Money.parse` | `-  minor = (Integer(T.must(match[2]), 10) * Currency.scale(currency)) + (if padded.empty?`<br>`+  minor = (Integer(match[2], 10) * Currency.scale(currency)) + (if padded.empty?` | [sorbet] Group 2 is `(\d+)`, not optional, so it is set whenever the regex matched; T.must is there for srb tc. |
| `Clearinghouse::Money#<=>` | `-  unless other.is_a?(Money) && other.currency == currency`<br>`+  unless other.instance_of?(Money) && other.currency == currency` | [subclass] Money has no subclasses. |
| `Clearinghouse::Money#==` | `-  unless other.is_a?(Money)`<br>`+  unless other.instance_of?(Money)` | [subclass] Money has no subclasses. |
| `Clearinghouse::Money#==` | `-  unless other.is_a?(Money)`<br>`-    return false`<br>`-  end`<br>`-  other.currency == currency && other.amount == amount`<br>`+  super` | Money includes Comparable, so `super` is Comparable#==, which is false when `<=>` returns nil (not Money, or another currency) and compares amounts otherwise. That is the same relation. The explicit method stays so equality does not depend on `<=>`'s nil rules. |
| `Clearinghouse::Money#to_s` | `-  sign = if amount.negative?`<br>`+  sign = if self.negative?` | Money#negative? is `amount.negative?`. |
| `Clearinghouse::Money#to_s` | `-  else`<br>`-    ""` | Without the else the sign is nil for a non-negative amount, and nil interpolates as an empty string. |
| `Clearinghouse::Money#to_s` | `-    ""`<br>`+    nil` | nil interpolates as an empty string. |
| `Clearinghouse::Money#to_s` | `-    whole.to_s`<br>`+    whole` | The branch value is only interpolated into the result, and interpolation calls the Integer's to_s anyway. |
| `Clearinghouse::Webhooks::Signature.compute` | `-  OpenSSL::HMAC.hexdigest("SHA256", secret.b, "#{timestamp_text}.".b + payload.b)`<br>`+  OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp_text}.".b + payload.b)` | OpenSSL::HMAC reads the key's bytes whatever its encoding; `.b` only relabels the same bytes. |
| `Clearinghouse::Webhooks::Signature.compute` | `-  OpenSSL::HMAC.hexdigest("SHA256", secret.b, "#{timestamp_text}.".b + payload.b)`<br>`+  OpenSSL::HMAC.hexdigest("SHA256", secret.b, "#{timestamp_text}." + payload.b)` | The prefix is ASCII digits and a dot, and an ASCII-only UTF-8 string concatenates with a binary one to the same bytes. (Dropping `.b` on the payload is not equivalent, and a UTF-16 payload test kills it.) |
| `Clearinghouse::Webhooks::Signature.parse` | `-  timestamp_text = T.let(nil, T.nilable(String))`<br>`+  timestamp_text = nil` | [sorbet] |
| `Clearinghouse::Webhooks::Signature.parse` | `-  signatures = T.let([], T::Array[String])`<br>`+  signatures = T.let([], T::Array[nil])` | [sorbet] The element type is erased at runtime. |
| `Clearinghouse::Webhooks::Signature.parse` | `-  header.b.split(",", -1).each { \|raw\|`<br>`+  header.b.split(",", -1) { \|raw\|` | String#split with a block yields each piece in order, the same as calling each on the array; the return value is unused. |
| `Clearinghouse::Webhooks::Signature.parse` | `-  header.b.split(",", -1).each { \|raw\|`<br>`+  header.b.split(",", -2).each { \|raw\|` | Any negative limit means the same thing to String#split: no limit, keep trailing empty fields. |
| `Clearinghouse::Webhooks::Signature.verify` | `-  Result.new(error: nil, timestamp: parsed.timestamp)`<br>`+  Result.new(timestamp: parsed.timestamp)` | `error` is a nilable T::Struct prop, so leaving it out sets it to nil. The explicit nil is there for the reader. |
| `Clearinghouse::Webhooks::Signature.verify!` | `-  T.must(result.timestamp)`<br>`+  result.timestamp` | [sorbet] verify sets the timestamp on every result whose error is nil, and that is the only way to get here. |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v4` | `-  hit && Denial.new(reason: hit[1], detail: "#{address} is in #{cidr(hit[0])}")`<br>`+  hit && Denial.new(reason: hit.fetch(1), detail: "#{address} is in #{cidr(hit[0])}")` | [index] `hit` is one of the two-element range tuples. |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v4` | `-  hit && Denial.new(reason: hit[1], detail: "#{address} is in #{cidr(hit[0])}")`<br>`+  hit && Denial.new(reason: hit.at(1), detail: "#{address} is in #{cidr(hit[0])}")` | [index] |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v4` | `-  hit && Denial.new(reason: hit[1], detail: "#{address} is in #{cidr(hit[0])}")`<br>`+  hit && Denial.new(reason: hit[1], detail: "#{address} is in #{cidr(hit.fetch(0))}")` | [index] |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v4` | `-  hit && Denial.new(reason: hit[1], detail: "#{address} is in #{cidr(hit[0])}")`<br>`+  hit && Denial.new(reason: hit[1], detail: "#{address} is in #{cidr(hit.at(0))}")` | [index] |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v6` | `-    detail = "#{address} is in #{cidr(hit[0])}"`<br>`+    detail = "#{address} is in #{cidr(hit.fetch(0))}"` | [index] |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v6` | `-    detail = "#{address} is in #{cidr(hit[0])}"`<br>`+    detail = "#{address} is in #{cidr(hit.at(0))}"` | [index] |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v6` | `-    if ["ipv4_mapped", "ipv4_compatible"].include?(hit[1])`<br>`+    if ["ipv4_mapped", "ipv4_compatible"].include?(hit.fetch(1))` | [index] |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v6` | `-    if ["ipv4_mapped", "ipv4_compatible"].include?(hit[1])`<br>`+    if ["ipv4_mapped", "ipv4_compatible"].include?(hit.at(1))` | [index] |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v6` | `-    return Denial.new(reason: hit[1], detail:)`<br>`+    return Denial.new(reason: hit.fetch(1), detail:)` | [index] |
| `Clearinghouse::Webhooks::Egress::IpPolicy.denial_v6` | `-    return Denial.new(reason: hit[1], detail:)`<br>`+    return Denial.new(reason: hit.at(1), detail:)` | [index] |
| `Clearinghouse::Webhooks::Egress::IpPolicy.embedded` | `-  IPAddr.new((address.to_i >> shift) & 4294967295, Socket::AF_INET)`<br>`+  IPAddr.new((address >> shift) & 4294967295, Socket::AF_INET)` | IPAddr#>> and #& work on the address's integer value, and IPAddr.new accepts the resulting IPAddr; checked by hand for the NAT64 and 6to4 cases, which give the same IPv4 address. |
| `Clearinghouse::Webhooks::Egress::IpPolicy.embedded` | `-  IPAddr.new((address.to_i >> shift) & 4294967295, Socket::AF_INET)`<br>`+  IPAddr.new((Integer(address) >> shift) & 4294967295, Socket::AF_INET)` | Integer() on an IPAddr calls its to_i. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  unless port.is_a?(Integer) && port.between?(1, 65535)`<br>`+  unless port.between?(1, 65535)` | Only http and https URLs reach this line, and URI gives both a default port, so `port` is always an Integer here (the spec's `https://host:/` style cases confirm URI never returns nil for them). The type check is defence in depth against a URI change. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  unless port.is_a?(Integer) && port.between?(1, 65535)`<br>`+  unless port && port.between?(1, 65535)` | As above: port is always an Integer here. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  unless port.is_a?(Integer) && port.between?(1, 65535)`<br>`+  unless port.instance_of?(Integer) && port.between?(1, 65535)` | [subclass] Integer has no subclasses in practice; and port is always an Integer here. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  unless port.is_a?(Integer) && port.between?(1, 65535)`<br>`+  unless true && port.between?(1, 65535)` | As above: port is always an Integer here. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  unless port.is_a?(Integer) && port.between?(1, 65535)`<br>`+  unless Integer && port.between?(1, 65535)` | As above: port is always an Integer here. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-    return refuse("invalid_url", "port #{port.inspect}")`<br>`+    return refuse("invalid_url", "port #{port}")` | port is an Integer, whose inspect and to_s are the same string. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  if checked.is_a?(Refusal)`<br>`+  if checked.instance_of?(Refusal)` | [subclass] Refusal has no subclasses. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  request_uri = T.cast(uri, URI::HTTP).request_uri.to_s`<br>`+  request_uri = T.cast(uri, URI::HTTP).request_uri` | URI::HTTP#request_uri returns a String for any URI with a host, which every URI reaching this line has. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  request_uri = T.cast(uri, URI::HTTP).request_uri.to_s`<br>`+  request_uri = T.cast(uri, URI::HTTP).request_uri.to_str` | As above: it is already a String. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  Target.new(scheme:, host: checked[0], port:, request_uri:, literal_ip: checked[1], test_mode_localhost: localhost)`<br>`+  self.new(scheme:, host: checked[0], port:, request_uri:, literal_ip: checked[1], test_mode_localhost: localhost)` | Inside Target's singleton method `self` is Target. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  Target.new(scheme:, host: checked[0], port:, request_uri:, literal_ip: checked[1], test_mode_localhost: localhost)`<br>`+  Target.new(scheme:, host: checked.at(0), port:, request_uri:, literal_ip: checked[1], test_mode_localhost: localhost)` | [index] `checked` is the two-element tuple from host_check. |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  Target.new(scheme:, host: checked[0], port:, request_uri:, literal_ip: checked[1], test_mode_localhost: localhost)`<br>`+  Target.new(scheme:, host: checked.fetch(0), port:, request_uri:, literal_ip: checked[1], test_mode_localhost: localhost)` | [index] |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  Target.new(scheme:, host: checked[0], port:, request_uri:, literal_ip: checked[1], test_mode_localhost: localhost)`<br>`+  Target.new(scheme:, host: checked[0], port:, request_uri:, literal_ip: checked.fetch(1), test_mode_localhost: localhost)` | [index] |
| `Clearinghouse::Webhooks::Egress::Target.check_uri` | `-  Target.new(scheme:, host: checked[0], port:, request_uri:, literal_ip: checked[1], test_mode_localhost: localhost)`<br>`+  Target.new(scheme:, host: checked[0], port:, request_uri:, literal_ip: checked.at(1), test_mode_localhost: localhost)` | [index] |
| `Clearinghouse::Webhooks::Egress::Target.host_check` | `-  labels = host.split(".", -1)`<br>`+  labels = host.split(".", -2)` | Any negative limit means the same thing to String#split. |
| `Clearinghouse::Webhooks::Egress::Target.host_check` | `-  if NUMERIC_LABEL.match?(labels.last.to_s)`<br>`+  if NUMERIC_LABEL.match?(labels.last.to_str)` | The host is non-empty (checked earlier), so split returns at least one label and `last` is a String. |
| `Clearinghouse::Webhooks::Egress::Target.host_check` | `-  if NUMERIC_LABEL.match?(labels.last.to_s)`<br>`+  if NUMERIC_LABEL.match?(labels.last)` | As above: `last` is never nil here. The to_s is for srb tc. |
| `Clearinghouse::Webhooks::Egress::Target.host_check` | `-  [host, nil]`<br>`+  [host]` | The caller reads the second element with `[1]`, which is nil for a one-element array too. |
| `Clearinghouse::Ledger::AccountCode.build` | `-  new(code:, kind: shape[0], normal_side: shape[1], owner_id:)`<br>`+  new(code:, kind: shape.at(0), normal_side: shape[1], owner_id:)` | [index] `shape` is a two-element pair from the PLATFORM or MERCHANT constant. |
| `Clearinghouse::Ledger::AccountCode.build` | `-  new(code:, kind: shape[0], normal_side: shape[1], owner_id:)`<br>`+  new(code:, kind: shape.fetch(0), normal_side: shape[1], owner_id:)` | [index] |
| `Clearinghouse::Ledger::AccountCode.build` | `-  new(code:, kind: shape[0], normal_side: shape[1], owner_id:)`<br>`+  new(code:, kind: shape[0], normal_side: shape.at(1), owner_id:)` | [index] |
| `Clearinghouse::Ledger::AccountCode.build` | `-  new(code:, kind: shape[0], normal_side: shape[1], owner_id:)`<br>`+  new(code:, kind: shape[0], normal_side: shape.fetch(1), owner_id:)` | [index] |
| `Clearinghouse::Ledger::AccountCode.parse` | `-  (scope, *rest) = code.split(":", -1)`<br>`+  (scope, *rest) = code.split(":", -2)` | Any negative limit means the same thing to String#split. |
| `Clearinghouse::Ledger::AccountCode.parse` | `-  (scope, *rest) = code.split(":", -1)`<br>`+  (scope, *rest) = code.split(":", 167)` | A limit only matters for a code with 167 or more fields, and then `rest` has 166 elements with either limit, which neither the platform (1) nor the merchant (2) branch accepts. Trailing empty fields are kept by any non-zero limit. |
| `Clearinghouse::Ledger::AccountCode.parse` | `-    build(code, PLATFORM[rest.fetch(0)], nil)`<br>`+    build(code, PLATFORM[rest.fetch(-1)], nil)` | The branch requires `rest.length == 1`, so the first and last element are the same. |
| `Clearinghouse::Ledger::Checker.run` | `-    row[:id].nil?`<br>`+    row.fetch(:id).nil?` | Every row of QUERY has an `id` column (it selects `r.*`), so `[]` and `fetch` agree. |
| `Clearinghouse::Ledger::Checker.run` | `-    Drift.new(account_id: Integer(row.fetch(:id)), code: row.fetch(:code), currency: row.fetch(:currency), stored: row[:stored]&.then { \|v\|`<br>`+    Drift.new(account_id: row.fetch(:id), code: row.fetch(:code), currency: row.fetch(:currency), stored: row[:stored]&.then { \|v\|` | [pg-int] |
| `Clearinghouse::Ledger::Checker.run` | `-      Integer(v)`<br>`+      v` | [pg-int] |
| `Clearinghouse::Ledger::Checker.run` | `-  Report.new(accounts_checked: Integer(rows.fetch(0).fetch(:accounts_checked)), drifts:)`<br>`+  Report.new(accounts_checked: rows.fetch(0).fetch(:accounts_checked), drifts:)` | [pg-int] |
| `Clearinghouse::Ledger::Checker.run` | `-  Report.new(accounts_checked: Integer(rows.fetch(0).fetch(:accounts_checked)), drifts:)`<br>`+  Report.new(accounts_checked: Integer(rows.fetch(-1).fetch(:accounts_checked)), drifts:)` | `total` is a single row joined onto every result row, so every row carries the same count. |
| `Clearinghouse::Ledger::Checker::Drift#to_s` | `-    Money.of(T.must(stored), currency).to_s`<br>`+    Money.of(T.must(stored), currency)` | The value is only interpolated into a string, which calls to_s anyway. |
| `Clearinghouse::Ledger::Checker::Drift#to_s` | `-    Money.of(T.must(stored), currency).to_s`<br>`+    Money.of(stored, currency).to_s` | [sorbet] This branch only runs when `stored` is not nil. |
| `Clearinghouse::Ledger::Clearing.explainability` | `-    [row[0], row[1]]`<br>`+    [row.at(0), row[1]]` | [index] Each row is the four-element tuple built two lines above. |
| `Clearinghouse::Ledger::Clearing.explainability` | `-    [row[0], row[1]]`<br>`+    [row.fetch(0), row[1]]` | [index] |
| `Clearinghouse::Ledger::Clearing.explainability` | `-    [row[0], row[1]]`<br>`+    [row[0], row.at(1)]` | [index] |
| `Clearinghouse::Ledger::Clearing.explainability` | `-    [row[0], row[1]]`<br>`+    [row[0], row.fetch(1)]` | [index] |
| `Clearinghouse::Ledger::Clearing.explainability` | `-      row[2]`<br>`+      row.at(2)` | [index] (appears twice: the volume and the explained volume sums) |
| `Clearinghouse::Ledger::Clearing.explainability` | `-      row[2]`<br>`+      row.fetch(2)` | [index] (appears twice) |
| `Clearinghouse::Ledger::Clearing.flow_nets` | `-  nets = T.let({}, T::Hash[String, T::Hash[ClearingKey, Integer]])`<br>`+  nets = T.let({}, T::Hash[nil, T::Hash[ClearingKey, Integer]])` | [sorbet] |
| `Clearinghouse::Ledger::Clearing.flow_nets` | `-  nets = T.let({}, T::Hash[String, T::Hash[ClearingKey, Integer]])`<br>`+  nets = T.let({}, T::Hash[String, nil])` | [sorbet] |
| `Clearinghouse::Ledger::Clearing.flow_nets` | `-  nets = T.let({}, T::Hash[String, T::Hash[ClearingKey, Integer]])`<br>`+  nets = T.let({}, T::Hash[String, Hash[ClearingKey, Integer]])` | [sorbet] |
| `Clearinghouse::Ledger::Clearing.flow_nets` | `-  nets = T.let({}, T::Hash[String, T::Hash[ClearingKey, Integer]])`<br>`+  nets = T.let({}, T::Hash[String, T::Hash])` | [sorbet] |
| `Clearinghouse::Ledger::Clearing.flow_nets` | `-  nets = T.let({}, T::Hash[String, T::Hash[ClearingKey, Integer]])`<br>`+  nets = T.let({}, T::Hash[String, T::Hash[nil, Integer]])` | [sorbet] |
| `Clearinghouse::Ledger::Clearing.flow_nets` | `-  nets = T.let({}, T::Hash[String, T::Hash[ClearingKey, Integer]])`<br>`+  nets = T.let({}, T::Hash[String, T::Hash[ClearingKey, nil]])` | [sorbet] |
| `Clearinghouse::Ledger::Clearing.flow_nets` | `-  db.fetch(FLOW_NETS).each { \|row\|`<br>`+  db.fetch(FLOW_NETS) { \|row\|` | Sequel's Database#fetch with a block iterates the rows, the same as calling each on the dataset. |
| `Clearinghouse::Ledger::Clearing.flow_summaries` | `-    first = rows.fetch(0)`<br>`+    first = rows.fetch(-1)` | `first` is only read for flow_type and opened_at, which come from the flow's one first transaction and are the same on every row of the group (the rows differ only by currency). |
| `Clearinghouse::Ledger::Clearing.orphans` | `-  behind = T.let({}, T::Hash[ClearingKey, Integer])`<br>`+  behind = T.let({}, T::Hash[nil, Integer])` | [sorbet] |
| `Clearinghouse::Ledger::Clearing.orphans` | `-  behind = T.let({}, T::Hash[ClearingKey, Integer])`<br>`+  behind = T.let({}, T::Hash[ClearingKey, nil])` | [sorbet] |
| `Clearinghouse::Ledger::Clearing.orphans` | `-    stored = Integer(row.fetch(:balance))`<br>`+    stored = row.fetch(:balance)` | [pg-int] |
| `Clearinghouse::Ledger::Clearing.orphans` | `-    OrphanBalance.new(code: key[0], currency: key[1], stored:, open_flows_total: behind.fetch(key, 0))`<br>`+    OrphanBalance.new(code: key.at(0), currency: key[1], stored:, open_flows_total: behind.fetch(key, 0))` | [index] `key` is the [code, currency] pair built two lines above. |
| `Clearinghouse::Ledger::Clearing.orphans` | `-    OrphanBalance.new(code: key[0], currency: key[1], stored:, open_flows_total: behind.fetch(key, 0))`<br>`+    OrphanBalance.new(code: key.fetch(0), currency: key[1], stored:, open_flows_total: behind.fetch(key, 0))` | [index] |
| `Clearinghouse::Ledger::Clearing.orphans` | `-    OrphanBalance.new(code: key[0], currency: key[1], stored:, open_flows_total: behind.fetch(key, 0))`<br>`+    OrphanBalance.new(code: key[0], currency: key.at(1), stored:, open_flows_total: behind.fetch(key, 0))` | [index] |
| `Clearinghouse::Ledger::Clearing.orphans` | `-    OrphanBalance.new(code: key[0], currency: key[1], stored:, open_flows_total: behind.fetch(key, 0))`<br>`+    OrphanBalance.new(code: key[0], currency: key.fetch(1), stored:, open_flows_total: behind.fetch(key, 0))` | [index] |
| `Clearinghouse::Ledger::Explain.accumulate` | `-  amount = Integer(row.fetch(:amount))`<br>`+  amount = row.fetch(:amount)` | [pg-int] |
| `Clearinghouse::Ledger::Explain.run` | `-  clearing = T.let({}, T::Hash[ClearingKey, Integer])`<br>`+  clearing = T.let({}, T::Hash[nil, Integer])` | [sorbet] |
| `Clearinghouse::Ledger::Explain.run` | `-  clearing = T.let({}, T::Hash[ClearingKey, Integer])`<br>`+  clearing = T.let({}, T::Hash[ClearingKey, nil])` | [sorbet] |
| `Clearinghouse::Ledger::Explain.run` | `-  Explanation.new(flow_id:, flow_type: rows.fetch(0).fetch(:flow_type), steps:)`<br>`+  Explanation.new(flow_id:, flow_type: rows.fetch(1).fetch(:flow_type), steps:)` | Every row is one entry of the flow, a flow has at least one transaction of at least two entries (enforced by the database), and posting refuses a second flow_type for a flow_id, so every row has the same flow_type and there is always a second row. |
| `Clearinghouse::Ledger::Explain.run` | `-  Explanation.new(flow_id:, flow_type: rows.fetch(0).fetch(:flow_type), steps:)`<br>`+  Explanation.new(flow_id:, flow_type: rows.fetch(-1).fetch(:flow_type), steps:)` | As above: every row has the same flow_type. |
| `Clearinghouse::Ledger::Explain.step` | `-first = rows.fetch(0)`<br>`+first = rows.fetch(1)` | All rows of one chunk belong to the same transaction, so they share id, description, times and reversal links, and a transaction has at least two entries, so there is a second row. |
| `Clearinghouse::Ledger::Explain.step` | `-first = rows.fetch(0)`<br>`+first = rows.fetch(-1)` | All rows of one chunk belong to the same transaction, so they share id, description, times and reversal links, and a transaction has at least two entries, so there is a second row. |
| `Clearinghouse::Ledger::Explain.step` | `-Line.new(account: row.fetch(:code), kind: row.fetch(:kind).to_sym, side: Entry.side_from_column(row.fetch(:side)), amount: Money.of(Integer(row.fetch(:amount)), row.fetch(:currency)))`<br>`+Line.new(account: row.fetch(:code), kind: row.fetch(:kind).to_sym, side: Entry.side_from_column(row.fetch(:side)), amount: Money.of(row.fetch(:amount), row.fetch(:currency)))` | [pg-int] |
| `Clearinghouse::Ledger::Explain.step` | `-Step.new(transaction_id: Integer(first.fetch(:id)), description: first.fetch(:description), effective_at: first.fetch(:effective_at), reverses_transaction_id: first[:reverses_transaction_id], reversed_by: first[:reversed_by], lines:, clearing_after: clearing)`<br>`+Step.new(transaction_id: first.fetch(:id), description: first.fetch(:description), effective_at: first.fetch(:effective_at), reverses_transaction_id: first[:reverses_transaction_id], reversed_by: first[:reversed_by], lines:, clearing_after: clearing)` | [pg-int] |
| `Clearinghouse::Ledger::Explain.step` | `-Step.new(transaction_id: Integer(first.fetch(:id)), description: first.fetch(:description), effective_at: first.fetch(:effective_at), reverses_transaction_id: first[:reverses_transaction_id], reversed_by: first[:reversed_by], lines:, clearing_after: clearing)`<br>`+Step.new(transaction_id: Integer(first.fetch(:id)), description: first.fetch(:description), effective_at: first.fetch(:effective_at), reverses_transaction_id: first.fetch(:reverses_transaction_id), reversed_by: first[:reversed_by], lines:, clearing_after: clearing)` | QUERY always selects both columns, so `[]` and `fetch` agree. |
| `Clearinghouse::Ledger::Explain.step` | `-Step.new(transaction_id: Integer(first.fetch(:id)), description: first.fetch(:description), effective_at: first.fetch(:effective_at), reverses_transaction_id: first[:reverses_transaction_id], reversed_by: first[:reversed_by], lines:, clearing_after: clearing)`<br>`+Step.new(transaction_id: Integer(first.fetch(:id)), description: first.fetch(:description), effective_at: first.fetch(:effective_at), reverses_transaction_id: first[:reverses_transaction_id], reversed_by: first.fetch(:reversed_by), lines:, clearing_after: clearing)` | QUERY always selects both columns, so `[]` and `fetch` agree. |
| `Clearinghouse::Ledger::ExplainPrinter.describe` | `-"#{step.description} (#{notes.join(", ")})"`<br>`+"#{step.description} (#{notes.join})"` | A step has at most one note: a reversal cannot itself be reversed (NotReversibleError), so "reverses" and "reversed by" never appear together and the separator is never used. |
| `Clearinghouse::Ledger::ExplainPrinter.describe` | `-"#{step.description} (#{notes.join(", ")})"`<br>`+"#{step.description} (#{notes.join(nil)})"` | A step has at most one note: a reversal cannot itself be reversed (NotReversibleError), so "reverses" and "reversed by" never appear together and the separator is never used. |
| `Clearinghouse::Ledger::ExplainPrinter.describe` | `-"#{step.description} (#{notes.join(", ")})"`<br>`+"#{step.description} (#{notes.join("")})"` | A step has at most one note: a reversal cannot itself be reversed (NotReversibleError), so "reverses" and "reversed by" never appear together and the separator is never used. |
| `Clearinghouse::Ledger::ExplainPrinter.line` | `-paint(text, styles[i], color)`<br>`+paint(text, styles.at(i), color)` | `Array#[]` with an Integer and `Array#at` are the same, including out of range. |
| `Clearinghouse::Ledger::ExplainPrinter.render` | `-lines = title(explanation, color), "", render_table(explanation, color:), "", *verdict(explanation, color)`<br>`+lines = title(explanation, color), nil, render_table(explanation, color:), "", *verdict(explanation, color)` | Array#join renders nil as an empty string and flattens a nested array, so the lines join to the same text. |
| `Clearinghouse::Ledger::ExplainPrinter.render` | `-lines = title(explanation, color), "", render_table(explanation, color:), "", *verdict(explanation, color)`<br>`+lines = title(explanation, color), "", render_table(explanation, color:), nil, *verdict(explanation, color)` | Array#join renders nil as an empty string and flattens a nested array, so the lines join to the same text. |
| `Clearinghouse::Ledger::ExplainPrinter.render` | `-lines = title(explanation, color), "", render_table(explanation, color:), "", *verdict(explanation, color)`<br>`+lines = title(explanation, color), "", render_table(explanation, color:), "", verdict(explanation, color)` | Array#join renders nil as an empty string and flattens a nested array, so the lines join to the same text. |
| `Clearinghouse::Ledger::ExplainPrinter.step_rows` | `-if net.nil?`<br>`-nil`<br>`-else`<br>`+unless net.nil?` | `net.nil? ? nil : clearing_style(net)` and `clearing_style(net) unless net.nil?` are the same expression. |
| `Clearinghouse::Ledger::ExplainPrinter.table` | `-}).map(&:length).max.to_i`<br>`+}).map(&:length).max` | The list is never empty here (a table always has a header; the verdict branch only runs with at least one open account), so `max` is an Integer and to_i, to_int and Integer() return it unchanged. |
| `Clearinghouse::Ledger::ExplainPrinter.table` | `-}).map(&:length).max.to_i`<br>`+}).map(&:length).max.to_int` | The list is never empty here (a table always has a header; the verdict branch only runs with at least one open account), so `max` is an Integer and to_i, to_int and Integer() return it unchanged. |
| `Clearinghouse::Ledger::ExplainPrinter.table` | `-([headers.fetch(i)] + rows.map { \|r\|`<br>`+Integer(([headers.fetch(i)] + rows.map { \|r\|`<br>`-}).map(&:length).max.to_i`<br>`+}).map(&:length).max)` | The list is never empty here (a table always has a header; the verdict branch only runs with at least one open account), so `max` is an Integer and to_i, to_int and Integer() return it unchanged. |
| `Clearinghouse::Ledger::ExplainPrinter.verdict` | `-["#{paint("Explained", :green, color)}: this flow never touched a clearing account."]`<br>`+"#{paint("Explained", :green, color)}: this flow never touched a clearing account."` | render splats the verdict into its lines; a bare String splats to itself, so one line either way. |
| `Clearinghouse::Ledger::ExplainPrinter.verdict` | `-["#{paint("Explained", :green, color)}: every clearing account this flow touched is back at zero."]`<br>`+"#{paint("Explained", :green, color)}: every clearing account this flow touched is back at zero."` | render splats the verdict into its lines; a bare String splats to itself, so one line either way. |
| `Clearinghouse::Ledger::ExplainPrinter.verdict` | `-}.max.to_i`<br>`+}.max` | The list is never empty here (a table always has a header; the verdict branch only runs with at least one open account), so `max` is an Integer and to_i, to_int and Integer() return it unchanged. |
| `Clearinghouse::Ledger::ExplainPrinter.verdict` | `-}.max.to_i`<br>`+}.max.to_int` | The list is never empty here (a table always has a header; the verdict branch only runs with at least one open account), so `max` is an Integer and to_i, to_int and Integer() return it unchanged. |
| `Clearinghouse::Ledger::ExplainPrinter.verdict` | `-width = open.keys.map { \|code, _\|`<br>`+width = Integer(open.keys.map { \|code, _\|`<br>`-}.max.to_i`<br>`+}.max)` | The list is never empty here (a table always has a header; the verdict branch only runs with at least one open account), so `max` is an Integer and to_i, to_int and Integer() return it unchanged. |
| `Clearinghouse::Ledger::ExplainPrinter.verdict` | `-["#{paint("Not explained", :red, color)}: money is still sitting in clearing.", *open.map { \|(code, currency), net\|`<br>`+["#{paint("Not explained", :red, color)}: money is still sitting in clearing.", open.map { \|(code, currency), net\|` | Without the splat the lines are a nested array, and Array#join flattens it: same text. |
| `Clearinghouse::Ledger::Posting#apply_balances` | `-deltas = T.let({}, T::Hash[Integer, Integer])`<br>`+deltas = T.let({}, T::Hash[nil, Integer])` | [sorbet] |
| `Clearinghouse::Ledger::Posting#apply_balances` | `-deltas = T.let({}, T::Hash[Integer, Integer])`<br>`+deltas = T.let({}, T::Hash[Integer, nil])` | [sorbet] |
| `Clearinghouse::Ledger::Posting#balance` | `-Money.of(Integer(amount \|\| 0), currency)`<br>`+Money.of(amount \|\| 0, currency)` | [pg-int] |
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-VALUES (?, ?, ?, ?, ?) ON CONFLICT (code, currency) DO NOTHING RETURNING id\n", key[0], key[1], parsed.kind.to_s, parsed.normal_side_column, parsed.owner_id).all`<br>`+VALUES (?, ?, ?, ?, ?) ON CONFLICT (code, currency) DO NOTHING RETURNING id\n", key.at(0), key[1], parsed.kind.to_s, parsed.normal_side_column, parsed.owner_id).all` | [index] `key` is a [code, currency] pair. |
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-VALUES (?, ?, ?, ?, ?) ON CONFLICT (code, currency) DO NOTHING RETURNING id\n", key[0], key[1], parsed.kind.to_s, parsed.normal_side_column, parsed.owner_id).all`<br>`+VALUES (?, ?, ?, ?, ?) ON CONFLICT (code, currency) DO NOTHING RETURNING id\n", key.fetch(0), key[1], parsed.kind.to_s, parsed.normal_side_column, parsed.owner_id).all` | [index] `key` is a [code, currency] pair. |
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-VALUES (?, ?, ?, ?, ?) ON CONFLICT (code, currency) DO NOTHING RETURNING id\n", key[0], key[1], parsed.kind.to_s, parsed.normal_side_column, parsed.owner_id).all`<br>`+VALUES (?, ?, ?, ?, ?) ON CONFLICT (code, currency) DO NOTHING RETURNING id\n", key[0], key.at(1), parsed.kind.to_s, parsed.normal_side_column, parsed.owner_id).all` | [index] `key` is a [code, currency] pair. |
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-VALUES (?, ?, ?, ?, ?) ON CONFLICT (code, currency) DO NOTHING RETURNING id\n", key[0], key[1], parsed.kind.to_s, parsed.normal_side_column, parsed.owner_id).all`<br>`+VALUES (?, ?, ?, ?, ?) ON CONFLICT (code, currency) DO NOTHING RETURNING id\n", key[0], key.fetch(1), parsed.kind.to_s, parsed.normal_side_column, parsed.owner_id).all` | [index] `key` is a [code, currency] pair. |
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-id = if inserted.empty?`<br>`+id = if inserted` | Always looking the account up after the insert finds the row this transaction just inserted, so the id is the same; the RETURNING id only saves a query. |
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-id = if inserted.empty?`<br>`+id = if true` | Always looking the account up after the insert finds the row this transaction just inserted, so the id is the same; the RETURNING id only saves a query. |
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-id = if inserted.empty?`<br>`-lookup_accounts([key]).fetch(key)`<br>`-else`<br>`-inserted.fetch(0).fetch(:id)`<br>`-end`<br>`+id = lookup_accounts([key]).fetch(key)` | Always looking the account up after the insert finds the row this transaction just inserted, so the id is the same; the RETURNING id only saves a query. |
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-inserted.fetch(0).fetch(:id)`<br>`+inserted.fetch(-1).fetch(:id)` | The insert is one row, so RETURNING gives at most one. |
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-ids[key] = Integer(id)`<br>`+ids[key] = id` | [pg-int] |
| `Clearinghouse::Ledger::Posting#entries_of` | `-@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|`<br>`+@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).map { \|row\|` | Selecting every column (or unqualified `code`) gives the same values: `code` exists only in ledger_accounts, and the entry's currency equals its account's by the composite foreign key, so the duplicate `currency` column cannot differ. |
| `Clearinghouse::Ledger::Posting#entries_of` | `-@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|`<br>`+@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries]).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|` | Ordering by the whole ledger_entries row compares its first column, id, first, and ids are unique. |
| `Clearinghouse::Ledger::Posting#entries_of` | `-@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|`<br>`+@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).select.map { \|row\|` | Selecting every column (or unqualified `code`) gives the same values: `code` exists only in ledger_accounts, and the entry's currency equals its account's by the composite foreign key, so the duplicate `currency` column cannot differ. |
| `Clearinghouse::Ledger::Posting#entries_of` | `-@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|`<br>`+@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).select(Sequel[:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|` | Selecting every column (or unqualified `code`) gives the same values: `code` exists only in ledger_accounts, and the entry's currency equals its account's by the composite foreign key, so the duplicate `currency` column cannot differ. |
| `Clearinghouse::Ledger::Posting#entries_of` | `-Entry.new(account: row.fetch(:code), side: Entry.side_from_column(row.fetch(:side)), amount: Money.of(Integer(row.fetch(:amount)), row.fetch(:currency)))`<br>`+Entry.new(account: row.fetch(:code), side: Entry.side_from_column(row.fetch(:side)), amount: Money.of(row.fetch(:amount), row.fetch(:currency)))` | [pg-int] |
| `Clearinghouse::Ledger::Posting#insert_transaction` | `-Integer(@db[:ledger_transactions].insert(flow_type:, flow_id:, description:, effective_at:, reverses_transaction_id: reverses))`<br>`+@db[:ledger_transactions].insert(flow_type:, flow_id:, description:, effective_at:, reverses_transaction_id: reverses)` | [pg-int] Sequel returns the new primary key as an Integer. |
| `Clearinghouse::Ledger::Posting#load_reversible!` | `-if original[:reverses_transaction_id]`<br>`+if original.fetch(:reverses_transaction_id)` | The row comes from a full select of ledger_transactions, which always has the column. |
| `Clearinghouse::Ledger::Posting#lookup_accounts` | `-found = T.let({}, T::Hash[AccountKey, Integer])`<br>`+found = T.let({}, T::Hash[nil, Integer])` | [sorbet] |
| `Clearinghouse::Ledger::Posting#lookup_accounts` | `-found = T.let({}, T::Hash[AccountKey, Integer])`<br>`+found = T.let({}, T::Hash[AccountKey, nil])` | [sorbet] |
| `Clearinghouse::Ledger::Posting#lookup_accounts` | `-@db[:ledger_accounts].where([:code, :currency] => keys).select(:id, :code, :currency).each { \|row\|`<br>`+@db[:ledger_accounts].where([:code, :currency] => keys).each { \|row\|` | Selecting every column instead of three gives the same id, code and currency. |
| `Clearinghouse::Ledger::Posting#lookup_accounts` | `-@db[:ledger_accounts].where([:code, :currency] => keys).select(:id, :code, :currency).each { \|row\|`<br>`+@db[:ledger_accounts].select(:id, :code, :currency).each { \|row\|` | Without the filter the result is a superset: every caller only reads the keys it asked for, so the extra accounts are never used. It costs a scan, not correctness. |
| `Clearinghouse::Ledger::Posting#lookup_accounts` | `-@db[:ledger_accounts].where([:code, :currency] => keys).select(:id, :code, :currency).each { \|row\|`<br>`+@db[:ledger_accounts].where([:code, :currency] => keys).select.each { \|row\|` | Selecting every column instead of three gives the same id, code and currency. |
| `Clearinghouse::Ledger::Posting#lookup_accounts` | `-found[[row.fetch(:code), row.fetch(:currency)]] = Integer(row.fetch(:id))`<br>`+found[[row.fetch(:code), row.fetch(:currency)]] = row.fetch(:id)` | [pg-int] |
| `Clearinghouse::Ledger::Posting#reverse` | `-if reason.strip.empty?`<br>`+if reason.lstrip.empty?` | A string is empty after strip exactly when it is all whitespace, and then lstrip and rstrip empty it too. |
| `Clearinghouse::Ledger::Posting#reverse` | `-if reason.strip.empty?`<br>`+if reason.rstrip.empty?` | A string is empty after strip exactly when it is all whitespace, and then lstrip and rstrip empty it too. |
| `Clearinghouse::Ledger::Posting#validate!` | `-accounts = T.let({}, T::Hash[AccountKey, AccountCode])`<br>`+accounts = T.let({}, T::Hash[nil, AccountCode])` | [sorbet] |
| `Clearinghouse::Ledger::Posting#validate!` | `-accounts = T.let({}, T::Hash[AccountKey, AccountCode])`<br>`+accounts = T.let({}, T::Hash[AccountKey, nil])` | [sorbet] |
| `Clearinghouse::Ledger::Posting#validate!` | `-nets = T.let({}, T::Hash[String, Integer])`<br>`+nets = T.let({}, T::Hash[nil, Integer])` | [sorbet] |
| `Clearinghouse::Ledger::Posting#validate!` | `-nets = T.let({}, T::Hash[String, Integer])`<br>`+nets = T.let({}, T::Hash[String, nil])` | [sorbet] |
<!-- equivalents:end -->

## Survivors not killed

These are not equivalent. Each could change behaviour, but killing it would take a test
that controls something the code does not expose: the planner's row order, or two
sessions paused between statements. They stay in the numbers as alive.

<!-- accepted:start -->
| Subject | Mutation | Why it is not killed |
|---|---|---|
| `Clearinghouse::Ledger::Posting#ensure_accounts` | `-accounts.keys.sort.each { \|key\|`<br>`+accounts.keys.each { \|key\|` | Not equivalent: the sort makes concurrent first postings that create the same new accounts take their row locks in one order, so they cannot deadlock. Killing it needs two sessions paused between their account inserts, and nothing in posting exposes that point. The six-thread spec exercises the balance-row order but not this one reliably. Left alive and counted as a survivor. |
| `Clearinghouse::Ledger::Posting#entries_of` | `-@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|`<br>`+@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|` | Not equivalent: without ORDER BY, Postgres may return a reversal's entries in any order. On these small tables it returns them in insertion order every time, so no test can see the difference. The entries still mirror the original and balance, only their order in the reversal could change. Left alive and counted as a survivor. |
| `Clearinghouse::Ledger::Posting#entries_of` | `-@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|`<br>`+@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order.select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|` | Not equivalent: without ORDER BY, Postgres may return a reversal's entries in any order. On these small tables it returns them in insertion order every time, so no test can see the difference. The entries still mirror the original and balance, only their order in the reversal could change. Left alive and counted as a survivor. |
| `Clearinghouse::Ledger::Posting#entries_of` | `-@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(Sequel[:ledger_entries][:id]).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|`<br>`+@db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id:).order(nil).select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency]).map { \|row\|` | Not equivalent: without ORDER BY, Postgres may return a reversal's entries in any order. On these small tables it returns them in insertion order every time, so no test can see the difference. The entries still mirror the original and balance, only their order in the reversal could change. Left alive and counted as a survivor. |
<!-- accepted:end -->

## Branch coverage gate

`bin/ci` fails when branch coverage drops below a floor in `spec/coverage_groups.rb`:
95% for the ledger and for the money core, and `PRODUCT_FLOOR` for product code as a
whole. Product code is `lib/clearinghouse/` without `testing/` and `experiments/`, plus
`sim/lib/acquirer_sim` and `clients/ruby/`. The experiment harnesses and test tooling
(`sim/experiments/`, `sim/fake_riskgate/`, `lib/clearinghouse/testing/`,
`lib/clearinghouse/experiments/`) are reported as their own group with no floor.

The floor used to cover all code, and it went red once the harnesses merged.
Harness code is exercised by the experiments themselves, in child processes that
`bin/crash-matrix`, `bin/storm` and `bin/exp-replay` spawn, where SimpleCov in the
rspec process cannot see it. It is not shipped. Gating on it would reward testing the
test rig instead of the product, so the floor now measures only the code that ships.
