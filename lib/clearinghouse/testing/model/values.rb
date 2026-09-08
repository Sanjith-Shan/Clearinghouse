# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # What one operation returned: success with a few fields the model promises,
      # or a typed error with the API's code (docs/api-errors.md).
      class Outcome < T::Struct
        extend T::Sig

        const :ok, T::Boolean
        const :code, T.nilable(String), default: nil
        const :decline_code, T.nilable(String), default: nil
        const :fields, T::Hash[String, T.untyped], default: {}

        sig { params(fields: T.untyped).returns(Outcome) }
        def self.success(**fields)
          new(ok: true, fields: fields.transform_keys(&:to_s))
        end

        sig { params(code: String, decline_code: T.nilable(String)).returns(Outcome) }
        def self.error(code, decline_code: nil)
          new(ok: false, code: code, decline_code: decline_code)
        end

        sig { returns(T::Boolean) }
        def ok?
          ok
        end

        sig { params(other: T.untyped).returns(T::Boolean) }
        def ==(other)
          return false unless other.is_a?(Outcome)

          [other.ok, other.code, other.decline_code, other.fields] == [ok, code, decline_code, fields]
        end

        sig { returns(String) }
        def to_s
          return "ok #{fields.map { |k, v| "#{k}=#{v}" }.join(' ')}".strip if ok

          decline_code ? "error #{code} (#{decline_code})" : "error #{code}"
        end
      end

      # One money movement the domain decided on, before it becomes ledger entries.
      # `kind` is the name of the Ledger::Flows builder a real implementation posts
      # for it. The reference model books its own entries for the same event; a
      # system under test turns the event into entries its own way, so the two
      # arithmetics stay independent.
      class Event < T::Struct
        const :kind, Symbol
        const :flow_id, String
        const :currency, String
        const :amount, Integer
        const :merchant, T.nilable(String), default: nil
        # Extra facts: the dispute fee for dispute_opened.
        const :fee, Integer, default: 0
      end

      # One step of a sequence: an operation name and its keyword arguments. Objects
      # are referred to by the symbolic names the sequence gave them (m1, pi_3, re_1,
      # po_2), which a system under test maps to its own ids.
      class Command < T::Struct
        extend T::Sig

        const :op, Symbol
        const :args, T::Hash[Symbol, T.untyped], default: {}

        sig { params(args: T::Hash[Symbol, T.untyped]).returns(Command) }
        def with_args(args)
          Command.new(op: op, args: args)
        end

        # A line of Ruby that replays this step on a Harness named `h`.
        sig { returns(String) }
        def to_ruby
          return "h.#{op}" if args.empty?

          "h.#{op}(#{args.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')})"
        end
      end

      # Captured and refunded totals for one payment, as the system under test
      # reports them.
      class IntentAmounts < T::Struct
        const :captured, Integer
        const :refunded, Integer
      end

      AccountKey = T.type_alias { [String, String] } # [account code, currency]

      # Everything the checks compare after a step. Balances are signed on each
      # account's normal side and only non-zero ones are listed, so an account that
      # exists with a zero balance and one that does not exist compare equal.
      class Snapshot < T::Struct
        const :balances, T::Hash[AccountKey, Integer]
        # flow id => clearing account => net still in it, on the account's normal side
        const :open_flows, T::Hash[String, T::Hash[AccountKey, Integer]]
        const :intents, T::Hash[String, IntentAmounts]
        # Problems the system's own checks found (ledger invariants, orphan clearing
        # balances). Always empty for the model.
        const :ledger_violations, T::Array[String], default: []
      end
    end
  end
end
