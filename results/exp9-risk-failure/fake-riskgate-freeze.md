## fake-riskgate, freeze

3000 calls at 100.0/s, deadline 50 ms. **1038 went through unchecked** ({"breaker_open"=>1020, "timeout"=>18}).

Fault at 10.005s, restart at 20.005s, first checked payment after restart at 20.357s.

Load average (1/5/15 min) before 28.89/21.95/31.27, after 43.8/26.03/32.42.

| phase | calls | unchecked | p50 ms | p99 ms | p99.9 ms | max ms | service p99 ms |
|---|---|---|---|---|---|---|---|
| healthy | 1001 | 0 | 3.988 | 9.202 | 13.029 | 16.32 | 7.469 |
| down_breaker_closed | 10 | 10 | 53.372 | 58.535 | 58.535 | 58.535 | 57.282 |
| breaker_open | 990 | 990 | 1.955 | 12.752 | 55.941 | 55.941 | 2.268 |
| recovering | 35 | 34 | 1.636 | 6.522 | 6.522 | 6.522 | 4.189 |
| healthy_after | 964 | 4 | 4.337 | 32.539 | 55.386 | 55.386 | 27.828 |
| overall | 3000 | 1038 | 3.349 | 27.399 | 55.386 | 58.535 | 19.771 |

Breaker transitions:

- 10.103s closed -> open (5 consecutive failures)
- 12.113s open -> half_open (cool-down elapsed)
- 12.163s half_open -> open (probe failed)
- 14.172s open -> half_open (cool-down elapsed)
- 14.223s half_open -> open (probe failed)
- 16.231s open -> half_open (cool-down elapsed)
- 16.284s half_open -> open (probe failed)
- 18.29s open -> half_open (cool-down elapsed)
- 18.346s half_open -> open (probe failed)
- 20.353s open -> half_open (cool-down elapsed)
- 20.356s half_open -> closed (probe succeeded)
