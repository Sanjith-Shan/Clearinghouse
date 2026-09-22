# typed: true
# frozen_string_literal: true

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): the plan.
  module CrashMatrix
    # The variants run on top of the registry's points. Each names a crash point
    # that must exist in the registry; a variant whose point disappears fails the
    # plan instead of silently not running.
    VARIANTS = T.let([
      { flow: 'payment_intent.confirm', point: 'authorization_requested', moment: :after_commit,
        variant: 'acquirer_drop' }
    ].freeze, T::Array[T::Hash[Symbol, T.untyped]])

    # Every case to run, in registry order: one per Registry#crash_points entry,
    # then one per background crash point (Settlement.background_crash_points,
    # bin/poller's points per notification type), then the variants. Enumerated
    # from the two registries and nothing else, so a new flow, a new phase or a
    # new notification handler is in the matrix the moment it is registered, with
    # no change here. A flow nobody has written a scenario for is still planned:
    # its cases fail with MissingScenarioError when run, so they count against
    # the headline instead of disappearing from it. `only`
    # narrows it for development (substring match on the case name); a narrowed
    # run is reported as partial and makes no headline claim.
    sig do
      params(registry: Clearinghouse::Idempotency::Registry, only: T.nilable(T::Array[String]),
             variants: T::Boolean,
             background: T::Array[Clearinghouse::Idempotency::Registry::CrashPoint]).returns(T::Array[Case])
    end
    def self.plan(registry, only: nil, variants: true, background: Clearinghouse::Settlement.background_crash_points)
      points = registry.flows.to_h { |f| [f.name, f.recovery_points] }
      cases = registry.crash_points.map { |cp| case_for(points, cp.flow, cp.point, cp.moment) }
      cases += background_cases(background)
      if variants
        cases += VARIANTS.map do |v|
          unless points.fetch(v[:flow], []).include?(v[:point])
            raise ArgumentError, "variant #{v[:variant]} targets #{v[:flow]}:#{v[:point]}, which is not registered"
          end

          case_for(points, v[:flow], v[:point], v[:moment], variant: v[:variant])
        end
      end
      only ? cases.select { |c| only.any? { |o| c.name.include?(o) } } : cases
    end

    # Registered flows the harness cannot set up yet, requests and background jobs.
    sig do
      params(registry: Clearinghouse::Idempotency::Registry, scenarios: T::Hash[String, Scenario],
             background: T::Array[Clearinghouse::Idempotency::Registry::CrashPoint])
        .returns(T::Array[String])
    end
    def self.flows_without_scenario(registry, scenarios = SCENARIOS,
                                    background: Clearinghouse::Settlement.background_crash_points)
      registry.flows.map(&:name).reject { |name| scenarios.key?(name) } +
        background.map(&:flow).uniq.reject { |name| BACKGROUND_SCENARIOS.key?(name) }
    end

    # One case per background crash point. A background point is a single crash
    # moment whose name already says which side of the commit it is on, so
    # `previous` is only the point before it in the job's own order.
    sig { params(points: T::Array[Clearinghouse::Idempotency::Registry::CrashPoint]).returns(T::Array[Case]) }
    def self.background_cases(points)
      points.group_by(&:flow).flat_map do |flow, flow_points|
        flow_points.each_with_index.map do |cp, i|
          Case.new(flow: flow, point: cp.point, moment: cp.moment, background: true,
                   previous: i.zero? ? nil : T.must(flow_points[i - 1]).point)
        end
      end
    end

    sig do
      params(points: T::Hash[String, T::Array[String]], flow: String, point: String, moment: Symbol,
             variant: T.nilable(String)).returns(Case)
    end
    def self.case_for(points, flow, point, moment, variant: nil)
      order = points.fetch(flow)
      index = T.must(order.index(point))
      Case.new(flow: flow, point: point, moment: moment, previous: index.zero? ? nil : order[index - 1],
               variant: variant)
    end

    # Truncates every table but the migrator's, as the owner, with ordinary
    # triggers off for that one transaction (the ledger's append-only triggers
    # refuse TRUNCATE otherwise). The same method spec/support/db.rb uses.
    sig { params(owner: Sequel::Database).void }
    def self.reset_database!(owner)
      tables = owner.fetch("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map(:tablename) -
               %w[schema_migrations schema_info]
      owner.transaction do
        owner.run('SET LOCAL session_replication_role = replica')
        owner.run("TRUNCATE #{tables.map { |t| owner.literal(Sequel.identifier(t)) }.join(', ')} " \
                  'RESTART IDENTITY CASCADE')
      end
    end

    # A crash inside a phase's transaction must leave exactly what a crash right
    # after the previous phase's commit leaves. Each before_commit case's
    # snapshot at the crash is compared with the after_commit case at the
    # previous point (same flow, same setup), or, for `started`, with the case's
    # own snapshot taken just before the request was sent. Appends a
    # `rolled_back_phase_invisible` check to every before_commit case whose
    # partner ran.
    sig { params(results: T::Array[CaseResult]).void }
    def self.compare_rollbacks(results)
      after = results.select { |r| r.kase.moment == :after_commit && r.kase.variant.nil? }
                     .to_h { |r| [[r.kase.flow, r.kase.point], r] }
      results.each do |r|
        next unless r.kase.before_commit? && r.kase.variant.nil? && r.crash_snapshot

        label, expected = rollback_reference(r, after)
        next if expected.nil?

        r.check('rolled_back_phase_invisible', r.crash_snapshot == expected,
                "state at the crash differs from #{label}: #{r.crash_snapshot} vs #{expected}")
      end
    end

    # What a before_commit case's crash must look like, and what that is called.
    sig do
      params(result: CaseResult, after: T::Hash[[String, String], CaseResult])
        .returns([String, T.nilable(T::Hash[String, T.untyped])])
    end
    def self.rollback_reference(result, after)
      previous = result.kase.previous
      return ['the state before the request', result.baseline_snapshot] if previous.nil?

      ["#{result.kase.flow}:#{previous}", after[[result.kase.flow, previous]]&.crash_snapshot]
    end
  end
end
