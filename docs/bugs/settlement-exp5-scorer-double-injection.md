# Experiment 5's scorer assumed each line carries at most one discrepancy

**What broke.** The first version of `Experiments::ReconciliationMonth::Scorer` matched
each injected discrepancy to one exception on the same movement. The simulator only
promises one discrepancy per line *per file*, and a line deferred by `late` is a line again
in the file it moves to, so random injection can hit it twice. In the failing run a refund
line was deferred in the 2026-01-05 file and again in the 2026-01-06 file: two `late`
injections, one line, which arrived once. The reconciler reported it correctly (the SLA job
called it `missing` on the 6th, a day past due plus slack, and closed that exception itself
when the line arrived on the 7th with a `late` exception). The scorer called the second
`late` "detected as another type (missing)". A line deferred and then dropped by `missing`
has the same shape: its lateness can never be observed.

**What caught it.** `spec/experiments/reconciliation_month_spec.rb`, "a small month through
the API", which requires every injection to be detected with no false exceptions. Ids are
random, so the injection lands on different lines every run; the spec failed on one run in
two, and a loop over the same month found the case above on its second run.

**The fix.** One `late` exception now covers every `late` injection on its line, a `missing`
exception that closed itself because the line arrived late is counted as
`missing_then_arrived` rather than false, and a `late` whose line was then dropped is
`not_observable`. Each rule has its own scorer spec. The fix landed with the experiment's
first commit, "Experiment 5: a simulated month of reconciliation with injected
discrepancies". (Thinking through the same double-injection case while writing the
scorer, before any run, is also how I found that the reconciler reported a line that was
both late and wrong only as wrong; that one was fixed in the reconciler, in "Reconciler:
report lateness independently of a wrong amount or fee", and was not caught by a test.)
