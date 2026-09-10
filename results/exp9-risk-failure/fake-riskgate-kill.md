## fake-riskgate, kill

3000 calls at 100.0/s, deadline 50 ms. **1209 went through unchecked** ({"breaker_open"=>1199, "connection"=>10}).

Fault at 10.0s, restart at 20.001s, first checked payment after restart at 22.098s.

Load average (1/5/15 min) before 14.95/19.06/30.63, after 28.89/21.95/31.27.

| phase | calls | unchecked | p50 ms | p99 ms | p99.9 ms | max ms | service p99 ms |
|---|---|---|---|---|---|---|---|
| healthy | 1000 | 0 | 3.574 | 26.598 | 67.353 | 70.796 | 19.349 |
| down_breaker_closed | 5 | 5 | 1.564 | 6.951 | 6.951 | 6.951 | 5.051 |
| breaker_open | 995 | 995 | 1.834 | 8.365 | 15.377 | 15.377 | 1.455 |
| recovering | 210 | 209 | 2.04 | 9.048 | 17.963 | 17.963 | 4.673 |
| healthy_after | 790 | 0 | 4.001 | 40.179 | 91.659 | 91.659 | 17.684 |
| overall | 3000 | 1209 | 2.755 | 14.591 | 72.32 | 91.659 | 9.285 |

Breaker transitions:

- 10.042s closed -> open (5 consecutive failures)
- 12.042s open -> half_open (cool-down elapsed)
- 12.043s half_open -> open (probe failed)
- 14.052s open -> half_open (cool-down elapsed)
- 14.053s half_open -> open (probe failed)
- 16.062s open -> half_open (cool-down elapsed)
- 16.063s half_open -> open (probe failed)
- 18.063s open -> half_open (cool-down elapsed)
- 18.063s half_open -> open (probe failed)
- 20.073s open -> half_open (cool-down elapsed)
- 20.076s half_open -> open (probe failed)
- 22.081s open -> half_open (cool-down elapsed)
- 22.098s half_open -> closed (probe succeeded)
