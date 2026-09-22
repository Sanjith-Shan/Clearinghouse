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
has any. Two places needed help:

- `Currency` had no spec of its own, so its mutants fell back to every example under
  `Clearinghouse`, most of the suite. It now has `spec/unit/currency_spec.rb`.
- `Posting` is exercised through `Clearinghouse::Ledger.post!`, so `posting_spec.rb`
  says so with `mutant_expression` metadata, naming Posting and each facade method.
  Without it, Posting's mutants ran all 93 ledger examples, including the property
  tests, and timed out on a busy machine.

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
