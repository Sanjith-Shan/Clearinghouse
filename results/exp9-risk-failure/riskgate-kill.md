## riskgate, kill

3000 calls at 100.0/s, deadline 50 ms. **1627 went through unchecked** ({"breaker_open"=>1602, "connection"=>10, "timeout"=>15}).

Fault at 10.002s, restart at 20.003s, first checked payment after restart at 22.087s.

Load average (1/5/15 min) before 43.8/26.03/32.42, after 45.73/28.31/33.03.

| phase | calls | unchecked | p50 ms | p99 ms | p99.9 ms | max ms | service p99 ms |
|---|---|---|---|---|---|---|---|
| healthy | 1000 | 214 | 3.364 | 43.687 | 57.02 | 57.354 | 38.314 |
| down_breaker_closed | 5 | 5 | 2.734 | 3.75 | 3.75 | 3.75 | 1.983 |
| breaker_open | 996 | 996 | 1.821 | 10.632 | 32.955 | 32.955 | 1.49 |
| recovering | 208 | 207 | 1.793 | 4.182 | 6.507 | 6.507 | 0.609 |
| healthy_after | 791 | 205 | 2.896 | 28.719 | 57.792 | 57.792 | 26.88 |
| overall | 3000 | 1627 | 2.459 | 14.67 | 57.138 | 57.792 | 8.452 |

Breaker transitions:

- 7.547s closed -> open (5 consecutive failures)
- 9.569s open -> half_open (cool-down elapsed)
- 9.594s half_open -> closed (probe succeeded)
- 10.043s closed -> open (5 consecutive failures)
- 12.05s open -> half_open (cool-down elapsed)
- 12.051s half_open -> open (probe failed)
- 14.052s open -> half_open (cool-down elapsed)
- 14.053s half_open -> open (probe failed)
- 16.063s open -> half_open (cool-down elapsed)
- 16.063s half_open -> open (probe failed)
- 18.07s open -> half_open (cool-down elapsed)
- 18.071s half_open -> open (probe failed)
- 20.072s open -> half_open (cool-down elapsed)
- 20.073s half_open -> open (probe failed)
- 22.082s open -> half_open (cool-down elapsed)
- 22.086s half_open -> closed (probe succeeded)
- 27.967s closed -> open (5 consecutive failures)
- 29.97s open -> half_open (cool-down elapsed)
- 29.973s half_open -> closed (probe succeeded)
