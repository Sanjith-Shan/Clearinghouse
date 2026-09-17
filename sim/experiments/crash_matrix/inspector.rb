# typed: true
# frozen_string_literal: true

require 'json'

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): reading the outcome.
  module CrashMatrix
    # Makes two runs of the same request comparable. It rewrites exactly two
    # things, and nothing else:
    #
    # 1. Generated ids become `<prefix#n>`, numbered by first appearance within
    #    one document: Clearinghouse's (`pi_`, `ch_`, `re_`, `evt_`, `req_` + 24
    #    alphanumerics), the simulator's (`acq_` + 24 hex), and RiskGate's
    #    assessment ids (`asm_` + digits, a counter in the fake RiskGate). The same id in two places gets the same
    #    placeholder, so the shape of the references is still compared: a body
    #    whose latest_charge pointed at the wrong charge would not normalise equal.
    # 2. The value of every key named `created` (a Unix timestamp of when the
    #    object was created; the crashed run and the control create their objects
    #    at different seconds).
    #
    # Everything else, every amount, status, count, error code and key order,
    # must match exactly.
    module Normalize
      extend T::Sig

      ID = /\b([a-z]+)_[A-Za-z0-9]{24}\b|\b(asm)_\d+\b/

      sig { params(value: T.untyped, table: T::Hash[String, String]).returns(T.untyped) }
      def self.call(value, table = {})
        case value
        when Hash
          value.to_h { |k, v| [k, k == 'created' && v.is_a?(Integer) ? '<created>' : call(v, table)] }
        when Array then value.map { |v| call(v, table) }
        when String then ids(value, table)
        else value
        end
      end

      sig { params(text: String, table: T::Hash[String, String]).returns(String) }
      def self.ids(text, table)
        text.gsub(ID) do |id|
          table[id] ||= begin
            match = T.must(Regexp.last_match)
            prefix = match[1] || match[2]
            "<#{prefix}##{table.count { |k, _| k.start_with?("#{prefix}_") } + 1}>"
          end
        end
      end

      # A JSON body, parsed and normalised; the raw text if it is not JSON.
      sig { params(body: String).returns(T.untyped) }
      def self.body(body)
        call(JSON.parse(body))
      rescue JSON::ParserError
        body
      end
    end

    # Reads what the database and the simulator say about a case.
    class Inspector
      extend T::Sig

      sig { params(db: Sequel::Database, sim: SimAdmin).void }
      def initialize(db:, sim:)
        @db = db
        @sim = sim
      end

      # The whole of the merchant's state that a phase can change, with nothing
      # that legitimately differs between two runs (ids, times, lease tokens). Two
      # snapshots are equal when the same work is durable. `key` is the case's
      # Idempotency-Key.
      sig { params(merchant_id: String, key: String).returns(T::Hash[String, T.untyped]) }
      def snapshot(merchant_id, key)
        Normalize.call({
                         'key' => key_state(merchant_id, key),
                         'payment_intents' => @db[:payment_intents].where(merchant_id: merchant_id)
                                                                   .order(:created_at, :id).map { |r| intent_state(r) },
                         'refunds' => @db[:refunds].where(merchant_id: merchant_id).order(:created_at, :id)
                                                   .map { |r| r.slice(:status, :amount).transform_keys(&:to_s) },
                         'events' => @db[:events].where(merchant_id: merchant_id).order(:seq).select_map(:type),
                         'ledger' => @db[:ledger_transactions].order(:id).select_map(%i[flow_type description])
                       })
      end

      # The case's key row, as far as recovery is concerned.
      sig { params(merchant_id: String, key: String).returns(T.nilable(T::Hash[String, T.untyped])) }
      def key_state(merchant_id, key)
        row = @db[:idempotency_keys].where(merchant_id: merchant_id, key: key).first
        return nil unless row

        { 'recovery_point' => row[:recovery_point], 'leased' => !row[:lock_token].nil?,
          'response_code' => row[:response_code],
          'flow_state' => Clearinghouse::DB.from_json(row[:flow_state]).keys.sort }
      end

      sig { params(merchant_id: String, key: String).returns(T.nilable(Time)) }
      def locked_at(merchant_id, key)
        @db[:idempotency_keys].where(merchant_id: merchant_id, key: key).get(:locked_at)
      end

      # Everything that happened to one PaymentIntent, from both sides: its row,
      # its refunds, every event about it, its charge or its refunds, its ledger
      # transactions with amounts, and the simulator's authorizations and
      # operations for it. Normalised, so the crashed run's facts can be compared
      # with the control's. `keys` maps Idempotency-Keys to a role name.
      sig do
        params(intent_id: String, acquirer: T::Hash[String, T.untyped],
               keys: T::Hash[String, String]).returns(T::Hash[String, T.untyped])
      end
      def facts(intent_id, acquirer, keys: {})
        Normalize.call(raw_facts(intent_id, acquirer, keys))
      end

      sig do
        params(intent_id: String, acquirer: T::Hash[String, T.untyped],
               keys: T::Hash[String, String]).returns(T::Hash[String, T.untyped])
      end
      def raw_facts(intent_id, acquirer, keys)
        intent = @db[:payment_intents].where(id: intent_id).first || {}
        refunds = @db[:refunds].where(payment_intent_id: intent_id).order(:created_at, :id).all
        objects = [intent_id, intent[:latest_charge], *refunds.map { |r| r[:id] }].compact
        { 'intent' => intent_state(intent),
          'refunds' => refunds.map { |r| r.slice(:id, :status, :amount, :failure_reason).transform_keys(&:to_s) },
          'events' => events(objects, keys),
          'ledger' => ledger([intent_id, *refunds.map { |r| r[:id] }]),
          'acquirer' => acquirer_side(intent_id, intent[:acquirer_reference], acquirer) }
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def acquirer_books = @sim.operations

      # Rules that must hold for every PaymentIntent in the database: the
      # simulator's money equals the ledger's equals the intent's. Returns the
      # problems found, empty when there are none.
      sig { params(merchant_id: String, acquirer: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def money_problems(merchant_id, acquirer)
        @db[:payment_intents].where(merchant_id: merchant_id).order(:created_at).flat_map do |intent|
          intent_money_problems(intent, acquirer)
        end
      end

      # Ledger::Invariants (zero sum, balances match entries, every transaction
      # balanced) plus a separate run of Ledger::Checker, reported the same way.
      sig { returns(T::Array[String]) }
      def ledger_problems
        violations = Clearinghouse::Ledger::Invariants.check(@db).map { |v| "#{v.invariant}: #{v.detail}" }
        drifts = Clearinghouse::Ledger::Checker.run(@db).drifts.map { |d| "checker: #{d}" }
        violations + drifts
      end

      # Keys still unfinished and intents still owned by a request, after recovery.
      sig { params(merchant_id: String).returns(T::Array[String]) }
      def leftover_problems(merchant_id)
        open = @db[:idempotency_keys].where(merchant_id: merchant_id).exclude(recovery_point: 'finished')
                                     .select_map(%i[key recovery_point])
        owned = @db[:payment_intents].where(merchant_id: merchant_id).exclude(locked_by: nil).select_map(:id)
        open.map { |k, p| "key #{k} unfinished at #{p}" } + owned.map { |id| "#{id} still owned by a request" }
      end

      private

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def intent_state(row)
        return {} if row.empty?

        risk = Clearinghouse::DB.from_json(row[:risk])
        { 'status' => row[:status], 'amount' => row[:amount], 'amount_capturable' => row[:amount_capturable],
          'amount_received' => row[:amount_received], 'amount_refunded' => row[:amount_refunded],
          'attempt' => row[:attempt], 'owned' => !row[:locked_by].nil?, 'charged' => !row[:latest_charge].nil?,
          'cancellation_reason' => row[:cancellation_reason], 'risk' => risk }
      end

      sig { params(objects: T::Array[String], keys: T::Hash[String, String]).returns(T::Array[T.untyped]) }
      def events(objects, keys)
        @db[:events].where(object_id: objects).order(:seq).map do |e|
          { 'type' => e[:type], 'object' => e[:object_id],
            'idempotency_key' => e[:idempotency_key] && keys.fetch(e[:idempotency_key], 'other'),
            'data' => Clearinghouse::DB.from_json(e[:data]) }
        end
      end

      sig { params(flow_ids: T::Array[String]).returns(T::Array[T.untyped]) }
      def ledger(flow_ids)
        @db.fetch(<<~SQL, flow_ids).map { |r| r.transform_keys(&:to_s) }
          SELECT t.flow_id, t.flow_type, t.description,
                 sum(e.amount) FILTER (WHERE e.side = 'D')::bigint AS amount
            FROM ledger_transactions t JOIN ledger_entries e ON e.transaction_id = t.id
           WHERE t.flow_id IN ?
           GROUP BY t.id ORDER BY t.id
        SQL
      end

      sig do
        params(intent_id: String, reference: T.nilable(String),
               acquirer: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped])
      end
      def acquirer_side(intent_id, reference, acquirer)
        auths = acquirer.fetch('authorizations').select { |a| a['reference'] == intent_id }
        refs = [reference, *auths.map { |a| a['acquirer_reference'] }].compact
        ops = acquirer.fetch('operations').select do |op|
          op['reference'] == intent_id || refs.include?(op['acquirer_reference'])
        end
        { 'authorizations' => auths.map { |a| a.slice('status', 'amount', 'captured', 'refunded', 'voided') },
          'operations' => ops.map { |op| op.slice('type', 'status', 'amount', 'decline_code', 'idempotency_key') } }
      end

      sig do
        params(intent: T::Hash[Symbol, T.untyped], acquirer: T::Hash[String, T.untyped]).returns(T::Array[String])
      end
      def intent_money_problems(intent, acquirer)
        id = intent.fetch(:id)
        auths = acquirer_side(id, intent[:acquirer_reference], acquirer).fetch('authorizations')
        refunds = @db[:refunds].where(payment_intent_id: id).all
        ledger = ledger([id, *refunds.map { |r| r[:id] }])
        (authorization_problems(intent, auths) + capture_problems(intent, auths, ledger) +
          refund_problems(intent, auths, ledger, refunds)).map { |p| "#{id}: #{p}" }
      end

      # At most one approved authorization, and a canceled intent's is voided.
      sig { params(intent: T::Hash[Symbol, T.untyped], auths: T::Array[T.untyped]).returns(T::Array[String]) }
      def authorization_problems(intent, auths)
        approved = auths.count { |a| a['status'] == 'approved' }
        problems = approved > 1 ? ["#{approved} approved authorizations at the acquirer"] : []
        if intent[:status] == 'canceled' && approved.positive? && auths.none? { |a| a['voided'] }
          problems << "canceled, but the acquirer's authorization was never voided"
        end
        problems
      end

      # What the acquirer captured = the ledger's one capture = amount_received.
      sig do
        params(intent: T::Hash[Symbol, T.untyped], auths: T::Array[T.untyped],
               ledger: T::Array[T.untyped]).returns(T::Array[String])
      end
      def capture_problems(intent, auths, ledger)
        captures = ledger.select { |t| t['description'] == 'capture' }
        amounts = { 'acquirer' => auths.sum { |a| a['captured'] }, 'ledger' => captures.sum { |t| t['amount'] },
                    'intent' => intent[:amount_received] }
        problems = captures.length > 1 ? ["#{captures.length} capture transactions in the ledger"] : []
        problems << "captured #{amounts}" unless amounts.values.uniq.length == 1
        problems
      end

      # What the acquirer refunded = the ledger's refunds = amount_refunded = the
      # succeeded refunds.
      sig do
        params(intent: T::Hash[Symbol, T.untyped], auths: T::Array[T.untyped], ledger: T::Array[T.untyped],
               refunds: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Array[String])
      end
      def refund_problems(intent, auths, ledger, refunds)
        refunded = { 'acquirer' => auths.sum { |a| a['refunded'] },
                     'ledger' => ledger.select { |t| t['flow_type'] == Clearinghouse::Ledger::Flows::REFUND }
                                       .sum { |t| t['amount'] },
                     'intent' => intent[:amount_refunded],
                     'refunds' => refunds.select { |r| r[:status] == 'succeeded' }.sum { |r| r[:amount] } }
        refunded.values.uniq.length == 1 ? [] : ["refunded #{refunded}"]
      end
    end
  end
end
