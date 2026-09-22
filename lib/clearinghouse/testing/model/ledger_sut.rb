# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # The money side of every operation, executed through the real ledger against
      # real Postgres: Ledger::Flows builds the entries, Ledger.post! writes them,
      # Ledger.balance and Ledger::Clearing read them back.
      #
      # There is no domain code on main yet (payments, refunds, disputes and payouts
      # are being built), so the domain decisions (is this transition legal, did the
      # card decline, which settlement lines arrived) come from a shadow copy of the
      # reference model, and this adapter does what the domain code will do with the
      # money:
      #
      # - it computes our fee with FeeSchedule and the acquirer's with the simulator's
      #   schedule, not with the model's arithmetic;
      # - it posts the Ledger::Flows builder for each event under the object's flow id;
      # - it decides payouts itself, reading available balance with
      #   Ledger.balance_for_update inside the posting's transaction, which is what
      #   the payouts code must do;
      # - it reports balances, open clearing flows, captured and refunded amounts and
      #   invariant violations from the database.
      #
      # So a sequence tests the ledger, the flow builders, the fee code and the
      # payout balance rule against the model. It does not test domain logic; ApiSut
      # does, once the endpoints exist. Flows and the fee calculation are injectable
      # so a planted bug can be run through it (PlantedBugs).
      class LedgerSut
        extend T::Sig
        include Sut

        FeeCalculator = T.type_alias { T.proc.params(schedule: FeeSchedule, gross: Money).returns(Money) }
        FLOW_TYPES = T.let({ 'pi' => Ledger::Flows::PAYMENT, 're' => Ledger::Flows::REFUND,
                             'dp' => Ledger::Flows::DISPUTE, 'po' => Ledger::Flows::PAYOUT }.freeze,
                           T::Hash[String, String])
        DEFAULT_FEE = T.let(->(schedule, gross) { schedule.fee_for(gross) }, FeeCalculator)

        # Captured per payment flow and refunded per refund flow, from the entries.
        AMOUNTS = <<~SQL
          SELECT t.flow_id, t.flow_type, sum(e.amount) AS total
            FROM ledger_entries e
            JOIN ledger_transactions t ON t.id = e.transaction_id
            JOIN ledger_accounts a ON a.id = e.account_id
           WHERE (t.flow_type = 'payment' AND a.code = 'platform:processor_receivable' AND e.side = 'D')
              OR (t.flow_type = 'refund' AND a.code = 'platform:refund_clearing' AND e.side = 'C')
           GROUP BY t.flow_id, t.flow_type
        SQL

        sig do
          params(db: Sequel::Database, owner_db: Sequel::Database, flows: T.untyped,
                 fee: FeeCalculator).void
        end
        def initialize(db:, owner_db:, flows: Ledger::Flows, fee: DEFAULT_FEE)
          @db = db
          @owner_db = owner_db
          @flows = flows
          @fee = fee
          @shadow = T.let(ReferenceModel.new, ReferenceModel)
          @clock = T.let(Clock::Test.new(start: Policy::START), Clock::Test)
          @fee_schedules = T.let({}, T::Hash[String, FeeSchedule])
          @nets = T.let({}, T::Hash[String, Money])
          @refund_intents = T.let({}, T::Hash[String, String])
          @payouts = T.let([], T::Array[String])
        end

        sig { override.void }
        def reset!
          DbReset.ledger!(@owner_db)
          @shadow.reset!
          @clock = Clock::Test.new(start: Policy::START)
          [@fee_schedules, @nets, @refund_intents].each(&:clear)
          @payouts.clear
        end

        sig do
          override.params(merchant: String, fee_rate_scaled: Integer, fee_fixed: T::Hash[String, Integer])
                  .returns(Outcome)
        end
        def create_merchant(merchant:, fee_rate_scaled:, fee_fixed:)
          outcome = @shadow.create_merchant(merchant: merchant, fee_rate_scaled: fee_rate_scaled, fee_fixed: fee_fixed)
          @fee_schedules[merchant] = FeeSchedule.new(rate_scaled: fee_rate_scaled, fixed_minor: fee_fixed) if outcome.ok
          outcome
        end

        sig do
          override.params(intent: String, merchant: String, amount: Integer, currency: String,
                          capture_method: String, payment_method: T.nilable(String)).returns(Outcome)
        end
        def create_intent(intent:, merchant:, amount:, currency:, capture_method:, payment_method: nil)
          posting do
            @shadow.create_intent(intent: intent, merchant: merchant, amount: amount, currency: currency,
                                  capture_method: capture_method, payment_method: payment_method)
          end
        end

        sig { override.params(intent: String, payment_method: String).returns(Outcome) }
        def confirm(intent:, payment_method:)
          posting { @shadow.confirm(intent: intent, payment_method: payment_method) }
        end

        sig { override.params(intent: String, amount: T.nilable(Integer)).returns(Outcome) }
        def capture(intent:, amount: nil)
          posting { @shadow.capture(intent: intent, amount: amount) }
        end

        sig { override.params(intent: String).returns(Outcome) }
        def cancel(intent:)
          posting { @shadow.cancel(intent: intent) }
        end

        sig { override.params(refund: String, intent: String, amount: T.nilable(Integer)).returns(Outcome) }
        def refund(refund:, intent:, amount: nil)
          outcome = posting { @shadow.refund(refund: refund, intent: intent, amount: amount) }
          @refund_intents[refund] = intent if outcome.ok
          outcome
        end

        # Decided here, against the real balance, not by the shadow model.
        sig do
          override.params(payout: String, merchant: String, currency: String, amount: T.nilable(Integer))
                  .returns(Outcome)
        end
        def payout(payout:, merchant:, currency:, amount: nil)
          # The shadow follows along so later notifications know about the payout.
          @shadow.payout(payout: payout, merchant: merchant, currency: currency, amount: amount)
          @shadow.drain_events
          return Outcome.error('resource_missing') unless @fee_schedules.key?(merchant)
          if @payouts.include?(payout) || !Policy::CURRENCIES.include?(currency) || (amount && !amount.positive?)
            return Outcome.error('parameter_invalid')
          end

          T.let(@db.transaction { pay_out(payout, merchant, currency, amount) }, Outcome)
        end

        sig { override.params(hours: Integer).returns(Outcome) }
        def advance_clock(hours:)
          outcome = posting { @shadow.advance_clock(hours: hours) }
          @clock.advance(hours * Policy::HOUR) if outcome.ok
          outcome
        end

        sig { override.params(intent: String, outcome: String).returns(Outcome) }
        def resolve_dispute(intent:, outcome:)
          posting { @shadow.resolve_dispute(intent: intent, outcome: outcome) }
        end

        sig { override.returns(Outcome) }
        def settle
          posting { @shadow.settle }
        end

        sig { override.returns(Outcome) }
        def availability_sweep
          posting { @shadow.availability_sweep }
        end

        sig { override.returns(Snapshot) }
        def snapshot
          report = Ledger::Clearing.report(@db, as_of: @clock.now, slas: {})
          violations = Ledger::Invariants.check(@db).map { |v| "#{v.invariant}: #{v.detail}" } +
                       report.orphan_balances.map do |o|
                         "orphan clearing balance: #{o.code} (#{o.currency}) stored #{o.stored}, open flows " \
                           "account for #{o.open_flows_total}"
                       end
          Snapshot.new(balances: balances, open_flows: report.open_flows.to_h { |f| [f.flow_id, f.unexplained] },
                       intents: intent_amounts, ledger_violations: violations)
        end

        private

        # Runs a shadow operation, then posts the money it moved, all in one database
        # transaction, the way a domain operation commits its state and its entries
        # together.
        sig { params(blk: T.proc.returns(Outcome)).returns(Outcome) }
        def posting(&blk)
          outcome = blk.call
          events = @shadow.drain_events
          @db.transaction { events.each { |event| post_event(event) } } unless events.empty?
          outcome
        end

        sig do
          params(payout: String, merchant: String, currency: String, amount: T.nilable(Integer)).returns(Outcome)
        end
        def pay_out(payout, merchant, currency, amount)
          available = Ledger.balance_for_update(@db, Ledger::AccountCode.merchant(merchant, 'available'), currency)
          return Outcome.error('balance_insufficient') unless available.positive?

          value = amount ? Money.of(amount, currency) : available
          return Outcome.error('balance_insufficient') if value > available

          post(payout, 'payout', @flows.payout(merchant_id: merchant, amount: value))
          @payouts << payout
          Outcome.success(amount: value.amount, status: 'in_transit')
        end

        # rubocop:disable Metrics/CyclomaticComplexity
        sig { params(event: Event).void }
        def post_event(event)
          amount = Money.of(event.amount, event.currency)
          merchant = event.merchant.to_s
          entries =
            case event.kind
            when :capture then capture_entries(event.flow_id, merchant, amount)
            when :settlement
              acquirer = FeeSchedule.new(rate_scaled: Policy::ACQUIRER_RATE_SCALED,
                                         fixed_minor: { event.currency => Policy::ACQUIRER_FIXED_MINOR })
              @flows.settlement(gross: amount, acquirer_fee: acquirer.fee_for(amount))
            when :funds_available
              # Our own net from the capture, not the model's.
              net = @nets.fetch(event.flow_id)
              return unless net.positive?

              @flows.funds_available(merchant_id: merchant, net: net)
            when :refund then @flows.refund(merchant_id: merchant, amount: amount)
            when :refund_settled then @flows.refund_settled(amount: amount)
            when :dispute_opened
              @flows.dispute_opened(merchant_id: merchant, amount: amount, fee: Money.of(event.fee, event.currency))
            when :dispute_debited then @flows.dispute_debited(amount: amount)
            when :dispute_won then @flows.dispute_won(merchant_id: merchant, amount: amount)
            when :dispute_funds_returned then @flows.dispute_funds_returned(amount: amount)
            when :payout_paid then @flows.payout_paid(amount: amount)
            when :payout_failed then @flows.payout_failed(merchant_id: merchant, amount: amount)
            else raise ArgumentError, "the ledger adapter does not post #{event.kind} events"
            end
          post(event.flow_id, event.kind.to_s.tr('_', ' '), entries)
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        sig { params(flow_id: String, merchant: String, gross: Money).returns(T::Array[Ledger::Entry]) }
        def capture_entries(flow_id, merchant, gross)
          fee = @fee.call(@fee_schedules.fetch(merchant), gross)
          @nets[flow_id] = gross - fee
          @flows.capture(merchant_id: merchant, gross: gross, fee: fee)
        end

        sig { params(flow_id: String, description: String, entries: T::Array[Ledger::Entry]).void }
        def post(flow_id, description, entries)
          Ledger.post!(@db, flow_type: FLOW_TYPES.fetch(flow_id.split('_').first.to_s), flow_id: flow_id,
                            description: description, effective_at: @clock.now, entries: entries)
        end

        # Every non-zero balance, in one query. This reads the same account_balances
        # row Ledger.balance returns (one query per account made each step about ten
        # times slower); the ledger SUT spec checks the two agree, and the
        # ledger_invariants check holds that row to the sum of entries.
        sig { returns(T::Hash[AccountKey, Integer]) }
        def balances
          @db[:account_balances].join(:ledger_accounts, id: :account_id).exclude(balance: 0)
                                .select(:code, :currency, :balance).all.to_h do |row|
            [[row.fetch(:code), row.fetch(:currency)], Integer(row.fetch(:balance))]
          end
        end

        sig { returns(T::Hash[String, IntentAmounts]) }
        def intent_amounts
          captured = T.let({}, T::Hash[String, Integer])
          refunded = T.let(Hash.new(0), T::Hash[String, Integer])
          @db.fetch(AMOUNTS).each do |row|
            total = Integer(row.fetch(:total))
            if row.fetch(:flow_type) == Ledger::Flows::PAYMENT
              captured[row.fetch(:flow_id)] = total
            else
              intent = @refund_intents.fetch(row.fetch(:flow_id))
              refunded[intent] = refunded.fetch(intent, 0) + total
            end
          end
          captured.to_h do |intent, total|
            [intent, IntentAmounts.new(captured: total, refunded: refunded.fetch(intent, 0))]
          end
        end
      end

      # Empties the ledger between sequences. Ledger tables refuse DELETE by
      # trigger, so this runs as the owner with triggers off for one transaction,
      # like the spec helper does, and only against a database whose name says it
      # is a test database. DELETE rather than TRUNCATE: the tables hold a few
      # hundred rows at most, and TRUNCATE's fixed cost per table made it the
      # slowest part of a shrink, which resets once per candidate.
      module DbReset
        extend T::Sig

        class RefusedError < Clearinghouse::Error; end

        # Children before parents.
        LEDGER_TABLES = %w[account_balances ledger_entries ledger_transactions ledger_accounts].freeze

        sig { params(owner_db: Sequel::Database, extra_tables: T::Array[String]).void }
        def self.ledger!(owner_db, extra_tables: [])
          name = owner_db.get(Sequel.function(:current_database)).to_s
          raise RefusedError, "refusing to empty #{name}: not a test database" unless name.include?('test')

          existing = owner_db.fetch("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map(:tablename)
          owner_db.transaction do
            owner_db.run('SET LOCAL session_replication_role = replica')
            (extra_tables + LEDGER_TABLES).select { |t| existing.include?(t) }.each { |t| owner_db[t.to_sym].delete }
          end
        end
      end
    end
  end
end
