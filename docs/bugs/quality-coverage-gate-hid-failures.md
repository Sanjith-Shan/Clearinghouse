# The coverage gate reported coverage instead of the failing examples

**What broke.** The branch-coverage gate in `spec/spec_helper.rb` is meant to stay quiet
when examples already failed, so a red `bin/ci` shows the failures rather than a coverage
number. It decided that from `$ERROR_INFO` (the `SystemExit` rspec raises), but it read it
after `SimpleCov.result.format!`, and formatting rescues an exception internally, which
clears `$ERROR_INFO`. So on every failing run the gate saw no failure, printed "Coverage
gate failed" for the floors the partial run missed, and exited 2 instead of rspec's 1. CI
stayed red either way, but the last thing on screen blamed coverage.

**Caught by.** A full run on 2026-09-24 while the Postgres container was stopped from
outside: 532 examples failed on connection errors, and the run ended with "Coverage gate
failed: Ledger: branch coverage 47.17% is below 95.0%". A one-example probe showed
`$ERROR_INFO` was the `SystemExit` before `format!` and `nil` after it.

**Fix.** Read the exit status before formatting. The regression spec is "the gate in
spec_helper" in `spec/unit/coverage_groups_spec.rb`: it runs a child rspec with
`COVERAGE_GATE=1` on one failing example and expects exit status 1 and no gate message.
Fix commit: the one that adds this file, "Coverage gate: read the exit status before formatting the result".
