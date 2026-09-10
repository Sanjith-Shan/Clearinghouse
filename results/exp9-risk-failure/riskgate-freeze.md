## riskgate, freeze

3000 calls at 100.0/s, deadline 50 ms. **1033 went through unchecked** ({"breaker_open"=>1019, "timeout"=>14}).

Fault at 10.005s, restart at 20.001s, first checked payment after restart at 20.343s.

Load average (1/5/15 min) before 45.73/28.31/33.03, after 31.64/26.57/32.23.

| phase | calls | unchecked | p50 ms | p99 ms | p99.9 ms | max ms | service p99 ms |
|---|---|---|---|---|---|---|---|
| healthy | 1001 | 0 | 2.15 | 7.731 | 24.62 | 33.879 | 4.276 |
| down_breaker_closed | 10 | 10 | 55.799 | 57.492 | 57.492 | 57.492 | 55.306 |
| breaker_open | 990 | 990 | 1.153 | 2.659 | 56.914 | 56.914 | 0.858 |
| recovering | 34 | 33 | 1.237 | 3.422 | 3.422 | 3.422 | 3.358 |
| healthy_after | 965 | 0 | 2.353 | 7.706 | 16.517 | 16.517 | 4.392 |
| overall | 3000 | 1033 | 1.925 | 8.034 | 56.914 | 57.492 | 4.755 |

Breaker transitions:

- 10.107s closed -> open (5 consecutive failures)
- 12.112s open -> half_open (cool-down elapsed)
- 12.166s half_open -> open (probe failed)
- 14.172s open -> half_open (cool-down elapsed)
- 14.227s half_open -> open (probe failed)
- 16.231s open -> half_open (cool-down elapsed)
- 16.281s half_open -> open (probe failed)
- 18.283s open -> half_open (cool-down elapsed)
- 18.333s half_open -> open (probe failed)
- 20.34s open -> half_open (cool-down elapsed)
- 20.343s half_open -> closed (probe succeeded)
