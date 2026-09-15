# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # What is asserted after every step. Each check returns the problems it found
      # as strings; the first check with any problem names the failure, and the
      # shrinker keeps a smaller sequence only if it fails the same check.
      module Checks
        extend T::Sig

        # One failed check.
        class Violation < T::Struct
          const :check, Symbol
          const :details, T::Array[String]
        end

        ORDER = %i[outcome balances zero_sum refunds_within_captures completed_flows_cleared open_flows
                   ledger_invariants].freeze

        sig do
          params(model: ReferenceModel, expected: Outcome, actual: Outcome, model_snapshot: Snapshot,
                 sut_snapshot: Snapshot).returns(T.nilable(Violation))
        end
        def self.first_violation(model:, expected:, actual:, model_snapshot:, sut_snapshot:)
          found = {
            outcome: outcome(expected, actual),
            balances: balances(model_snapshot.balances, sut_snapshot.balances),
            zero_sum: zero_sum(sut_snapshot.balances),
            refunds_within_captures: refunds_within_captures(sut_snapshot.intents),
            completed_flows_cleared: completed_flows_cleared(model, sut_snapshot.open_flows),
            open_flows: open_flows(model_snapshot.open_flows, sut_snapshot.open_flows),
            ledger_invariants: sut_snapshot.ledger_violations
          }
          check = ORDER.find { |name| found.fetch(name).any? }
          check && Violation.new(check: check, details: found.fetch(check))
        end

        # Same success or failure, same error code and decline code, and the same
        # value for every field both sides report.
        sig { params(expected: Outcome, actual: Outcome).returns(T::Array[String]) }
        def self.outcome(expected, actual)
          same = expected.ok == actual.ok && expected.code == actual.code &&
                 expected.decline_code == actual.decline_code &&
                 (expected.fields.keys & actual.fields.keys).all? { |k| expected.fields[k] == actual.fields[k] }
          same ? [] : ["expected #{expected}, got #{actual}"]
        end

        sig { params(expected: T::Hash[AccountKey, Integer], actual: T::Hash[AccountKey, Integer]).returns(T::Array[String]) }
        def self.balances(expected, actual)
          (expected.keys | actual.keys).sort.filter_map do |key|
            want = expected.fetch(key, 0)
            got = actual.fetch(key, 0)
            "#{key[0]} (#{key[1]}): model #{want}, system #{got}, off by #{got - want}" unless want == got
          end
        end

        # Signed on the debit side, every currency sums to zero across all accounts.
        sig { params(balances: T::Hash[AccountKey, Integer]).returns(T::Array[String]) }
        def self.zero_sum(balances)
          sums = Hash.new(0)
          balances.each do |(code, currency), balance|
            debit_normal = Ledger::AccountCode.parse(code).normal_side == :debit
            sums[currency] += debit_normal ? balance : -balance
          end
          sums.reject { |_, sum| sum.zero? }.map { |currency, sum| "#{currency} debits minus credits is #{sum}" }
        end

        sig { params(intents: T::Hash[String, IntentAmounts]).returns(T::Array[String]) }
        def self.refunds_within_captures(intents)
          intents.select { |_, a| a.refunded > a.captured }
                 .map { |name, a| "#{name} refunded #{a.refunded} of #{a.captured} captured" }
        end

        # No flow the domain considers finished may still hold money in a clearing
        # account. Uses the model's domain state (what has settled, been paid, been
        # resolved), not its balances.
        sig do
          params(model: ReferenceModel, open: T::Hash[String, T::Hash[AccountKey, Integer]]).returns(T::Array[String])
        end
        def self.completed_flows_cleared(model, open)
          open.select { |flow_id, _| model.flow_complete?(flow_id) }.map do |flow_id, nets|
            "#{flow_id} is complete but still holds #{nets.map do |(code, cur), v|
              "#{v} #{cur} in #{code}"
            end.join(', ')}"
          end
        end

        sig do
          params(expected: T::Hash[String, T::Hash[AccountKey, Integer]],
                 actual: T::Hash[String, T::Hash[AccountKey, Integer]]).returns(T::Array[String])
        end
        def self.open_flows(expected, actual)
          (expected.keys | actual.keys).sort.filter_map do |flow_id|
            want = expected.fetch(flow_id, {})
            got = actual.fetch(flow_id, {})
            "#{flow_id}: model has #{want.inspect} in clearing, system has #{got.inspect}" unless want == got
          end
        end
      end
    end
  end
end
