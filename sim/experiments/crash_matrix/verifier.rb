# typed: true
# frozen_string_literal: true

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): the assertions about a case.
  module CrashMatrix
    # Everything a case asserts once it has crashed and recovered. Each check is
    # recorded by name with what it saw, pass or fail, so a report shows the
    # evidence and not just a verdict.
    class Verifier
      extend T::Sig

      sig { params(inspector: Inspector, recovery: String).void }
      def initialize(inspector:, recovery:)
        @inspector = inspector
        @recovery = recovery
      end

      # Right after the crash, the key row is at the last committed point.
      sig { params(work: Work).void }
      def check_crash_state(work)
        state = @inspector.key_state(work.merchant_id, work.key)
        got = state && state['recovery_point']
        expected = work.kase.expected_point_after_crash
        work.result.check('key_at_crash', got == expected, "key row at #{got.inspect}, expected #{expected.inspect}")
      end

      sig do
        params(work: Work, final: Reply, again: Reply, control_state: T::Hash[String, String], control: Reply).void
      end
      def verify(work, final:, again:, control_state:, control:)
        result = work.result
        books = @inspector.acquirer_books
        intent = work.scenario.intent_id(work.state, final)
        control_intent = work.scenario.intent_id(control_state, control)
        raise "no PaymentIntent to check (reply #{final})" unless intent && control_intent

        roles = key_roles(work)
        facts = @inspector.facts(intent, books, keys: roles)
        control_facts = @inspector.facts(control_intent, books, keys: roles)
        record(result, 'resting_state', work.scenario.resting_problems(facts))
        record(result, 'ledger_invariants', @inspector.ledger_problems)
        record(result, 'acquirer_equals_ledger', @inspector.money_problems(work.merchant_id, books))
        check_events(result, facts, control_facts)
        check_response(result, final, again, control)
        result.check('same_outcome_as_control', facts == control_facts, diff(facts, control_facts))
        record(result, 'nothing_left_locked', @inspector.leftover_problems(work.merchant_id))
        check_recovery_path(result)
      end

      private

      sig { params(result: CaseResult, name: String, problems: T::Array[String]).void }
      def record(result, name, problems)
        result.check(name, problems.empty?, problems.join('; '))
      end

      # Events carry the Idempotency-Key of the request that caused them; the
      # facts compare them by role, so an event attributed to the wrong request
      # shows up as a difference from the control.
      sig { params(work: Work).returns(T::Hash[String, String]) }
      def key_roles(work)
        [work.tag, work.control_tag].each_with_object({}) do |tag, roles|
          roles["#{tag}:request"] = 'request'
          roles["#{tag}:setup-create"] = 'setup-create'
          roles["#{tag}:setup-confirm"] = 'setup-confirm'
        end
      end

      # Exactly one event per state change: the crashed request's objects got the
      # same event types, in the same order, as the uninterrupted control's, and
      # no (object, type) pair appears twice.
      sig do
        params(result: CaseResult, facts: T::Hash[String, T.untyped], control: T::Hash[String, T.untyped]).void
      end
      def check_events(result, facts, control)
        types = facts.fetch('events').map { |e| [e['object'], e['type']] }
        expected = control.fetch('events').map { |e| [e['object'], e['type']] }
        duplicates = types.tally.select { |_, n| n > 1 }.keys
        result.check('one_event_per_change', types == expected && duplicates.empty?,
                     "events #{types.map(&:last)}, control #{expected.map(&:last)}, duplicated #{duplicates}")
      end

      # The recovered answer is the answer an uninterrupted request got (ids and
      # `created` normalised, see Normalize), and a further retry replays it byte
      # for byte.
      sig { params(result: CaseResult, final: Reply, again: Reply, control: Reply).void }
      def check_response(result, final, again, control)
        same = final.status == control.status && Normalize.body(final.body) == Normalize.body(control.body)
        result.check('same_response_as_control', same,
                     "recovered #{final.status} #{final.body[0, 300]} vs control #{control.status} " \
                     "#{control.body[0, 300]}")
        replay = again.status == final.status && again.body == final.body && again.replayed?
        result.check('retry_replays_it', replay, "second retry #{again}, replayed=#{again.replayed?}")
      end

      # Retry mode: every attempt before the answer was a 409 while the dead
      # process's lease ran; nothing else went wrong on the way. Completer mode:
      # the completer finished the key, so the client's retry was a replay. The
      # ambiguous variant also has its own path (check_ambiguous).
      sig { params(result: CaseResult).void }
      def check_recovery_path(result)
        check_ambiguous(result) if result.kase.variant == CaseRunner::DROP
        return check_completer(result) if @recovery == RecoveryMode::COMPLETER
        return if result.kase.variant == CaseRunner::DROP

        detours = result.recovery[0..-2].to_a.reject { |line| line.include?('409 idempotency_key_in_use') }
        result.check('recovered_without_detours', detours.empty?, detours.join('; '))
      end

      # A crash that left a key row leaves it for the completer, and the client
      # then only reads the stored answer. A crash that left none (the insert
      # rolled back) leaves the completer nothing, and the retry runs afresh.
      sig { params(result: CaseResult).void }
      def check_completer(result)
        left_a_key = !result.kase.expected_point_after_crash.nil?
        retry_line = result.recovery.last.to_s
        ok = left_a_key == retry_line.end_with?('(replayed)')
        result.check('completer_finished_it', ok,
                     "key left at the crash: #{left_a_key}; #{result.recovery.join('; ')}")
      end

      # The ambiguous acquirer: after the crash at authorization_requested, the
      # first resume asks GET /operations/<key> (nothing there), authorizes, and
      # the answer is dropped after the acquirer committed. The next resume must
      # ask again, find the authorization, and record it without a second POST.
      sig { params(result: CaseResult).void }
      def check_ambiguous(result)
        all = result.exchanges.except('crashed_request').values.flatten
        posts = all.count { |e| e.start_with?('POST /authorize') }
        dropped = all.index { |e| e.start_with?('POST /authorize') && e.end_with?('dropped') }
        asked = !dropped.nil? && all[(dropped + 1)..].to_a.any? do |e|
          e.start_with?('GET /operations/') && e.end_with?('200')
        end
        result.check('ambiguous_answer_resolved_by_asking', posts == 1 && asked,
                     "acquirer exchanges during recovery: #{all}")
      end

      sig { params(left: T.untyped, right: T.untyped).returns(String) }
      def diff(left, right)
        return '' if left == right
        return "#{left.inspect[0, 400]} vs #{right.inspect[0, 400]}" unless left.is_a?(Hash) && right.is_a?(Hash)

        (left.keys | right.keys).reject { |k| left[k] == right[k] }.map { |k| "#{k}: #{diff(left[k], right[k])}" }
                                .join('; ')
      end
    end
  end
end
