# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Experiments
    module ReconciliationMonth
      # Scores the reconciler's exceptions against the simulator's ground truth, the
      # manifest of each settlement file (docs/design/sim.md). The reconciler never
      # sees a manifest; only this does.
      #
      # An injected discrepancy is **detected** when an exception of the same type
      # names the same movement: acquirer reference, line type, and operation id
      # where the exception has one (a `missing` capture exception does not, because
      # our books never learn the acquirer's id for a capture). An exception matched
      # to nothing is a **false exception**. Each exception matches at most one
      # discrepancy, with one exception to the rule: the simulator can defer a line
      # that is already late again in the next file, and a line that arrives once is
      # reported late once, so one `late` exception covers every `late` injection on
      # its line. If the line is late by more than the reconciler's slack, the SLA job
      # also calls it missing first, and that exception closes itself when the line
      # arrives; those are counted as `missing_then_arrived`, not as false. And a line
      # deferred by `late` and then dropped by `missing` in the file it moved to never
      # arrives, so its lateness cannot be observed by anyone: that `late` is counted
      # as `not_observable` rather than as a miss.
      class Scorer
        extend T::Sig

        # One movement, as the acquirer identifies it.
        class Identity < T::Struct
          const :acquirer_reference, String
          const :line_type, String
          const :operation_id, T.nilable(String)
        end

        # One injected discrepancy, from a manifest.
        class Injected < T::Struct
          const :date, String
          const :type, String
          const :identity, Identity
        end

        sig do
          params(manifests: T::Array[T::Hash[String, T.untyped]], exceptions: T::Array[T::Hash[Symbol, T.untyped]])
            .void
        end
        def initialize(manifests:, exceptions:)
          @injected = T.let(manifests.flat_map { |m| injected(m) }, T::Array[Injected])
          @carried = T.let(manifests.flat_map { |m| m.fetch('carried_over') }.reject { |c| c['injected_late'] },
                           T::Array[T::Hash[String, T.untyped]])
          @exceptions = exceptions
        end

        sig { returns(T::Hash[String, T.untyped]) }
        def score
          used = T.let({}, T::Hash[String, T::Boolean])
          outcomes = outcomes(used)
          {
            'injected' => tally(@injected.map(&:type)),
            'detected' => tally(outcomes.select { |_, how| how == :detected }.map { |d, _| d.type }),
            'detected_as_another_type' => outcomes.select { |_, how| how.is_a?(String) }
                                                  .map { |d, how| { 'injected' => d.type, 'reported' => how } },
            'not_observable' => outcomes.select { |_, how| how == :not_observable }
                                        .map { |d, _| d.serialize.merge('identity' => d.identity.serialize) },
            'undetected' => outcomes.select { |_, how| how == :undetected }
                                    .map { |d, _| d.serialize.merge('identity' => d.identity.serialize) },
            'false_exceptions' => false_exceptions(used),
            'missing_then_arrived' => missing_then_arrived(used).length,
            'carried_over_not_injected' => @carried.length,
            'carried_over_flagged_late' => carried_flagged_late
          }
        end

        private

        # Each injected discrepancy with how it was reported. Exact matches are taken
        # first, so a line with two discrepancies (late in one file, then mismatched in
        # the next) is not scored by whichever came first.
        sig { params(used: T::Hash[String, T::Boolean]).returns(T::Array[[Injected, T.any(Symbol, String)]]) }
        def outcomes(used)
          dropped = @injected.select { |d| d.type == 'missing' }.map(&:identity)
          exact = @injected.to_h { |d| [d, match(d, used, exact_only: true)] }
          @injected.map do |d|
            next [d, :detected] if exact.fetch(d) == :detected
            next [d, :not_observable] if d.type == 'late' && dropped.any? { |i| i.serialize == d.identity.serialize }

            [d, match(d, used)]
          end
        end

        # Lines the acquirer carried over on its own that were reported late anyway
        # (a late line that was also injected late is reported late correctly). Any
        # other exception on such a line is scored like every other exception.
        sig { returns(Integer) }
        def carried_flagged_late
          injected_late = @injected.select { |d| d.type == 'late' }.map { |d| d.identity.serialize }
          @carried.map { |c| identity(c) }.reject { |i| injected_late.include?(i.serialize) }.count do |i|
            @exceptions.any? { |x| x.fetch(:reason) == 'late' && same?(i, x) }
          end
        end

        sig { params(used: T::Hash[String, T::Boolean]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
        def missing_then_arrived(used)
          late = @injected.select { |d| d.type == 'late' }.map(&:identity)
          @exceptions.reject { |x| used[x.fetch(:id)] }.select do |x|
            x.fetch(:reason) == 'missing' && x[:resolution_action] == 'auto' && late.any? { |i| same?(i, x) }
          end
        end

        sig { params(used: T::Hash[String, T::Boolean]).returns(T::Array[T::Hash[String, T.untyped]]) }
        def false_exceptions(used)
          superseded = missing_then_arrived(used).map { |x| x.fetch(:id) }
          @exceptions.reject { |x| used[x.fetch(:id)] || superseded.include?(x.fetch(:id)) }.map do |x|
            x.slice(:id, :reason, :flow_id, :line_type, :acquirer_reference, :detail).transform_keys(&:to_s)
          end
        end

        # :detected, the other reason it was reported as, or :undetected.
        sig do
          params(injected: Injected, used: T::Hash[String, T::Boolean], exact_only: T::Boolean)
            .returns(T.any(Symbol, String))
        end
        def match(injected, used, exact_only: false)
          candidates = @exceptions.select do |x|
            late_again = injected.type == 'late' && x.fetch(:reason) == 'late'
            same?(injected.identity, x) && (!used[x.fetch(:id)] || late_again)
          end
          exact = candidates.find { |x| x.fetch(:reason) == injected.type }
          chosen = exact || (exact_only ? nil : candidates.first)
          return :undetected unless chosen

          used[chosen.fetch(:id)] = true
          exact ? :detected : chosen.fetch(:reason)
        end

        sig { params(identity: Identity, exception: T::Hash[Symbol, T.untyped]).returns(T::Boolean) }
        def same?(identity, exception)
          operation = exception[:operation_id]
          exception[:acquirer_reference] == identity.acquirer_reference &&
            exception.fetch(:line_type) == identity.line_type &&
            (operation.nil? || operation == identity.operation_id)
        end

        sig { params(manifest: T::Hash[String, T.untyped]).returns(T::Array[Injected]) }
        def injected(manifest)
          manifest.fetch('discrepancies').map do |d|
            Injected.new(date: manifest.fetch('date'), type: d.fetch('type'), identity: identity(d))
          end
        end

        sig { params(entry: T::Hash[String, T.untyped]).returns(Identity) }
        def identity(entry)
          Identity.new(acquirer_reference: entry.fetch('acquirer_reference'), line_type: entry.fetch('line_type'),
                       operation_id: entry['operation_id'])
        end

        sig { params(values: T::Array[String]).returns(T::Hash[String, Integer]) }
        def tally(values)
          Reconciliation::REASONS.to_h { |reason| [reason, values.count(reason)] }
        end
      end
    end
  end
end
