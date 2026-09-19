# typed: true
# frozen_string_literal: true

module Clearinghouse
  # Everything that happens because time passed, in one process and in the order
  # the parts depend on. Each tick runs, in order:
  #
  #   1. expiry          authorizations past their capture window are canceled
  #   2. notifications   the acquirer's feed: disputes, and payout.paid / failed
  #   3. settlement      today's settlement file (and skipped days), pending lines
  #   4. missing lines   settlement lines overdue past their slack
  #   5. (extra_steps)   anything a deployment adds, before money moves
  #   6. availability    money due today moves pending -> available (or -> held
  #                      while its payment is under review)
  #   7. payouts         today's automatic payouts, which see what 2 and 6 did
  #   8. payout resume   automatic payouts that stopped half way
  #   9. completer       idempotent requests nobody is finishing
  #  10. reaper          finished idempotency keys past their 24 hours
  #
  # Every step is idempotent and safe to run concurrently with a copy of itself,
  # so a tick that dies half way is simply run again, and two schedulers can run
  # at once. A step that raises is reported and the tick goes on: a bank that is
  # down must not stop authorizations from expiring. docs/design/scheduler.md.
  class Scheduler
    extend T::Sig

    # One named step: what it does with the dependencies at this tick's clock,
    # returning a JSON-friendly summary.
    class Step < T::Struct
      const :name, String
      const :run, T.proc.params(deps: Api::Dependencies, clock: Clock).returns(T::Hash[String, T.untyped])
    end

    # What one tick did: each step's summary, and the error of each step that failed.
    class TickReport < T::Struct
      extend T::Sig

      const :at, Time
      const :results, T::Hash[String, T::Hash[String, T.untyped]]
      const :errors, T::Hash[String, String]

      sig { returns(T::Boolean) }
      def ok? = errors.empty?

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        { 'time' => at.utc.iso8601(3), 'steps' => results, 'errors' => errors }
      end
    end

    sig do
      params(deps: Api::Dependencies, grace: T.nilable(Numeric), limit: Integer,
             extra_steps: T::Array[Step]).void
    end
    def initialize(deps, grace: nil, limit: 100, extra_steps: [])
      @deps = deps
      @grace = grace
      @limit = limit
      @extra_steps = extra_steps
    end

    # How many days back settlement ingestion catches up after the scheduler was
    # down. Older files are an operator's job (bin/exp-reconciliation shows how).
    SETTLEMENT_CATCH_UP_DAYS = 7

    # The steps, in the order a tick runs them.
    sig { returns(T::Array[Step]) }
    def steps
      [
        Step.new(name: 'expiry', run: ->(deps, _) { { 'expired' => Payments::Expiry.sweep!(deps, limit: @limit) } }),
        *settlement_steps,
        *@extra_steps,
        Step.new(name: 'availability', run: lambda { |deps, clock|
          report = Balances::Availability.release_due!(deps.db, clock: clock)
          { 'available' => report.count('available'), 'held' => report.count('held') }
        }),
        Step.new(name: 'payouts', run: lambda { |deps, clock|
          { 'created' => Payouts.run_scheduled!(deps.db, bank: bank(deps), clock: clock).map(&:id) }
        }),
        Step.new(name: 'payout_resume', run: lambda { |deps, clock|
          { 'driven' => Payouts.resume_incomplete!(deps.db, bank: bank(deps), clock: clock).map(&:id) }
        }),
        Step.new(name: 'completer', run: lambda { |deps, _|
          report = Api::Completion.completer(deps, grace: @grace).run_once(limit: @limit)
          { 'completed' => report.completed, 'busy' => report.busy, 'failed' => report.failed.to_h }
        }),
        Step.new(name: 'reaper', run: lambda { |deps, clock|
          report = Idempotency::Reaper.run(deps.db, clock: clock)
          { 'deleted' => report.deleted, 'stuck' => report.stuck }
        })
      ]
    end

    # One pass over every step at `clock`'s now. Specs pass their test clock and
    # move it between ticks; the process passes the real one.
    sig { params(clock: Clock).returns(TickReport) }
    def tick!(clock = @deps.clock)
      deps = at(clock)
      results = {}
      errors = {}
      steps.each do |step|
        results[step.name] = step.run.call(deps, clock)
      rescue StandardError => e
        errors[step.name] = "#{e.class}: #{e.message}"
      end
      TickReport.new(at: clock.now, results: results, errors: errors)
    end

    # Ticks every `interval` seconds of real time until `stop` says so, writing
    # each report as one JSON line.
    sig do
      params(interval: Numeric, out: T.any(IO, StringIO), stop: T.proc.returns(T::Boolean),
             sleeper: T.proc.params(seconds: Numeric).void).void
    end
    def run(interval:, out:, stop:, sleeper: ->(seconds) { sleep(seconds) })
      loop do
        out.puts(JSON.generate(tick!.to_h))
        break if stop.call

        sleeper.call(interval)
        break if stop.call
      end
    end

    private

    # The acquirer's side, before any money moves this tick, in the order the
    # reconciliation experiment runs them (docs/design/reconciliation.md): the
    # notification feed first, so a dispute opened overnight has taken its money
    # out of available before today's payout is sized; then today's settlement
    # file, the pending lines retried, and the SLA check for lines that never came.
    sig { returns(T::Array[Step]) }
    def settlement_steps
      [
        Step.new(name: 'notifications', run: lambda { |deps, clock|
          result = Acquirer::NotificationPoller.new(
            db: deps.db, client: bank(deps), clock: clock,
            handlers: Settlement.notification_handlers(clock: clock)
          ).poll
          { 'processed' => result.processed, 'already_processed' => result.already_processed,
            'unavailable' => result.unavailable }
        }),
        Step.new(name: 'settlement', run: ->(deps, clock) { ingest_settlement(deps, clock) }),
        Step.new(name: 'missing_lines', run: lambda { |deps, clock|
          { 'raised' => Reconciliation::MissingDetector.new(db: deps.db, clock: clock).run.length }
        })
      ]
    end

    # Today's settlement file, and any day since the last file ingested that was
    # skipped, oldest first. A file already ingested is a no-op, so every tick of
    # the day after the first costs one lookup.
    sig { params(deps: Api::Dependencies, clock: Clock).returns(T::Hash[String, T.untyped]) }
    def ingest_settlement(deps, clock)
      today = clock.now.utc.to_date
      last = deps.db[:settlement_files].max(:settled_on)
      first = last ? [last + 1, today - SETTLEMENT_CATCH_UP_DAYS].max : today
      ingestor = Reconciliation::Ingestor.new(db: deps.db, client: bank(deps), clock: clock)
      files = (first..today).map { |date| ingestor.ingest(date) }
      { 'files' => files.to_h { |r| [r.date.iso8601, r.status] }, 'lines' => files.sum(&:lines),
        'pending_matched' => ingestor.match_pending }
    end

    # The dependencies with this tick's clock, so the steps that read time from
    # the dependencies (expiry, the completer) see the same now as the rest.
    sig { params(clock: Clock).returns(Api::Dependencies) }
    def at(clock)
      return @deps if clock.equal?(@deps.clock)

      props = Api::Dependencies.props.keys.to_h { |name| [name, @deps.public_send(name)] }
      props[:clock] = clock
      Api::Dependencies.new(**props)
    end

    sig { params(deps: Api::Dependencies).returns(Acquirer::Client) }
    def bank(deps)
      deps.acquirer || raise(Clearinghouse::Error, 'the scheduler needs an acquirer client to pay out')
    end
  end
end
