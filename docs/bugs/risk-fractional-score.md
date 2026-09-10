# A fractional risk_score made the RiskGate client raise instead of failing open

**What broke.** `Risk::Assessment.score` checked `risk_score` with `(0..99).include?(value)`.
`Range#include?` on an integer range answers true for `50.5`, so a response carrying a
fractional score passed the check and reached the struct, where sorbet-runtime raised
`TypeError` (the field is `Integer`). `Client#interpret` only rescues `JSON::ParserError` and
`Assessment::Invalid`, so the `TypeError` escaped `Client#assess`. The client's contract is
that it never raises for anything RiskGate sends, because the confirm path fails open on
`Unavailable`; this one would have turned a RiskGate encoding slip (say, a float score after a
model change) into a 500 on confirm.

**Caught by.** `spec/risk/assessment_spec.rb`, "refuses a fractional score", on its first
run: it expected `Assessment::Invalid` and got `TypeError`.

**Fix.** Check the class as well as the range: `value.is_a?(Integer) && SCORE_RANGE.include?(value)`.
The broken version was never committed, so the fix is part of the client commit, 616f84a
(branch `pr/risk-client`).
