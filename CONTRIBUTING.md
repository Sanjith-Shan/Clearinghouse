# Working in this repo

Every change lands on `main` through a branch that reads as one pull request, with the
template in `.github/pull_request_template.md` filled in and `bin/ci` green.

## Setup

```
brew install ruby@3.3 libpq
export PATH=/opt/homebrew/opt/ruby@3.3/bin:$PATH
bundle install
docker compose up -d db
bin/migrate && CLEARINGHOUSE_DB=clearinghouse_test bin/migrate
bin/ci
```

## Conventions

- **Time.** Nothing reads `Time.now`. Everything takes a `Clearinghouse::Clock`.
- **Money.** Integer minor units in `Clearinghouse::Money`. No floats anywhere near an amount.
- **Types.** `typed: strict` in `ledger/`, `idempotency/`, and the money core. `typed: true` elsewhere.
- **Migrations** are timestamp-named (`db/migrations/YYYYMMDDHHMMSS_name.rb`) so parallel
  branches never collide. Each one grants the app role exactly what it needs.
- **Design notes** go in `docs/design/<area>.md`. `DESIGN.md` links them.
- **Bugs the harness caught** go in `docs/bugs/NNN-short-name.md`: what broke, which test
  or experiment caught it, the fix commit. Real ones only.
- **Experiment output** goes in `results/<experiment>/` with the machine, Postgres
  version, pool size and command that produced it.
- **Timing specs.** Tight wall-clock bounds are tagged `:timing` and run only with
  `CLEARINGHOUSE_STRICT_TIMING=1`; each has a load-tolerant twin that always runs
  (docs/design/testing-timing.md). Run `CLEARINGHOUSE_STRICT_TIMING=1 bin/ci` on a quiet machine.
