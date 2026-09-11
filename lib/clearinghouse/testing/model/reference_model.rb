# typed: true
# frozen_string_literal: true

require 'date'

module Clearinghouse
  module Testing
    module Model
      # A plain-Ruby model of Clearinghouse's domain and money: merchants, payment
      # intents, refunds, disputes, payouts, balances and simulated time, with no
      # database. It is the specification the real system is compared against after
      # every step, so it is written to be obviously right rather than fast or clever,
      # and it books its own ledger entries rather than calling Ledger::Flows.
      #
      # Every operation returns the Outcome the API should give: success with a few
      # fields, or the typed error code. Money it moves is also recorded as Events,
      # which a ledger-level system under test posts through the real ledger.
      class ReferenceModel # rubocop:disable Metrics/ClassLength
        extend T::Sig
        include Sut

        # Normal side of every account the flows touch. Written out here, not read
        # from Ledger::AccountCode, for the same reason the fee is computed here.
        DEBIT_NORMAL = %w[platform:cash platform:processor_receivable platform:processing_expense
                          platform:dispute_losses].freeze
        CLEARING = %w[platform:processor_receivable platform:refund_clearing platform:dispute_clearing
                      platform:payout_clearing].freeze

        CASH = 'platform:cash'
        RECEIVABLE = 'platform:processor_receivable'
        REFUND_CLEARING = 'platform:refund_clearing'
        DISPUTE_CLEARING = 'platform:dispute_clearing'
        PAYOUT_CLEARING = 'platform:payout_clearing'
        FEE_REVENUE = 'platform:fee_revenue'
        DISPUTE_FEE_REVENUE = 'platform:dispute_fee_revenue'
        PROCESSING_EXPENSE = 'platform:processing_expense'

        CANCELABLE = %w[requires_payment_method requires_confirmation requires_capture].freeze
        CONFIRMABLE = %w[requires_payment_method requires_confirmation].freeze

        # A merchant and its fee schedule.
        class MerchantState < T::Struct
          const :name, String
          const :fee_rate_scaled, Integer
          const :fee_fixed, T::Hash[String, Integer]
        end

        # A PaymentIntent: its state machine position and its money.
        class IntentState < T::Struct
          const :name, String
          const :merchant, String
          const :amount, Integer
          const :currency, String
          const :capture_method, String
          prop :status, String
          prop :payment_method, T.nilable(String)
          prop :capturable, Integer, default: 0
          prop :received, Integer, default: 0
          prop :refunded, Integer, default: 0
          prop :fee, Integer, default: 0
          prop :available_on, T.nilable(Time)
          prop :made_available, T::Boolean, default: false
          prop :dispute, T.nilable(String)
          prop :authorization_expires_at, T.nilable(Time)
        end

        # A dispute, from the moment a capture schedules it at the acquirer.
        class DisputeState < T::Struct
          const :name, String
          const :intent, String
          const :merchant, String
          const :currency, String
          const :amount, Integer
          const :fee, Integer
          const :opens_at, Time
          # scheduled (only the acquirer knows), open, won, lost
          prop :status, String, default: 'scheduled'
        end

        # A payout, pending until the bank answers.
        class PayoutState < T::Struct
          const :name, String
          const :merchant, String
          const :currency, String
          const :amount, Integer
          const :arrives_at, Time
          prop :status, String, default: 'pending'
        end

        # A line the acquirer will put in a settlement file.
        class Movement < T::Struct
          const :kind, Symbol # :capture, :refund, :dispute, :dispute_reversal
          const :flow_id, String
          const :currency, String
          const :amount, Integer
          const :due_on, Date
          prop :settled, T::Boolean, default: false
        end

        sig { returns(Time) }
        attr_reader :now

        sig { returns(T::Hash[String, MerchantState]) }
        attr_reader :merchants

        sig { returns(T::Hash[String, IntentState]) }
        attr_reader :intents

        sig { returns(T::Hash[String, DisputeState]) }
        attr_reader :disputes

        sig { returns(T::Hash[String, PayoutState]) }
        attr_reader :payouts

        sig { returns(T::Hash[String, String]) }
        attr_reader :refunds # refund name => intent name

        sig { void }
        def initialize
          @now = T.let(Policy::START, Time)
          @merchants = T.let({}, T::Hash[String, MerchantState])
          @intents = T.let({}, T::Hash[String, IntentState])
          @disputes = T.let({}, T::Hash[String, DisputeState])
          @payouts = T.let({}, T::Hash[String, PayoutState])
          @refunds = T.let({}, T::Hash[String, String])
          @movements = T.let([], T::Array[Movement])
          @settled_files = T.let([], T::Array[Date])
          @balances = T.let({}, T::Hash[AccountKey, Integer])
          @flow_nets = T.let({}, T::Hash[String, T::Hash[AccountKey, Integer]])
          @events = T.let([], T::Array[Event])
        end

        sig { override.void }
        def reset!
          @now = Policy::START
          [@merchants, @intents, @disputes, @payouts, @refunds, @balances, @flow_nets].each(&:clear)
          [@movements, @settled_files, @events].each(&:clear)
        end

        # The money events of the operations since the last call.
        sig { returns(T::Array[Event]) }
        def drain_events
          events = @events
          @events = []
          events
        end

        # The next unused symbolic name of a kind: m1, pi_1, re_1, po_1. Reading it
        # changes nothing, so the generator can ask for names it may not use.
        sig { params(kind: Symbol).returns(String) }
        def next_name(kind)
          prefix, taken = { merchant: ['m', @merchants], intent: ['pi_', @intents], refund: ['re_', @refunds],
                            payout: ['po_', @payouts] }.fetch(kind)
          n = taken.size + 1
          n += 1 while taken.key?("#{prefix}#{n}")
          "#{prefix}#{n}"
        end

        sig { params(account: String, currency: String).returns(Integer) }
        def balance(account, currency)
          @balances.fetch([account, currency], 0)
        end

        sig { params(merchant: String, currency: String).returns(Integer) }
        def available(merchant, currency)
          balance("merchant:#{merchant}:available", currency)
        end

        # ---- operations ----------------------------------------------------------

        sig do
          override.params(merchant: String, fee_rate_scaled: Integer, fee_fixed: T::Hash[String, Integer])
                  .returns(Outcome)
        end
        def create_merchant(merchant:, fee_rate_scaled:, fee_fixed:)
          return Outcome.error('parameter_invalid') if @merchants.key?(merchant) || fee_rate_scaled.negative?

          @merchants[merchant] = MerchantState.new(name: merchant, fee_rate_scaled: fee_rate_scaled,
                                                   fee_fixed: fee_fixed)
          Outcome.success
        end

        sig do
          override.params(intent: String, merchant: String, amount: Integer, currency: String,
                          capture_method: String, payment_method: T.nilable(String)).returns(Outcome)
        end
        def create_intent(intent:, merchant:, amount:, currency:, capture_method:, payment_method: nil)
          return Outcome.error('resource_missing') unless @merchants.key?(merchant)
          return Outcome.error('parameter_invalid') if @intents.key?(intent)
          return Outcome.error('parameter_invalid') unless Policy::CURRENCIES.include?(currency)
          return Outcome.error('parameter_invalid') unless %w[automatic manual].include?(capture_method)
          return Outcome.error('parameter_invalid') unless amount.positive?
          return Outcome.error('resource_missing') if payment_method && !known_card?(payment_method)
          return Outcome.error('amount_too_small') unless covers_fee?(merchant, amount, currency)

          status = payment_method ? 'requires_confirmation' : 'requires_payment_method'
          @intents[intent] = IntentState.new(name: intent, merchant: merchant, amount: amount, currency: currency,
                                             capture_method: capture_method, status: status,
                                             payment_method: payment_method)
          Outcome.success(status: status, amount: amount)
        end

        sig { override.params(intent: String, payment_method: String).returns(Outcome) }
        def confirm(intent:, payment_method:)
          pi = @intents[intent]
          return Outcome.error('resource_missing') unless pi
          return Outcome.error('payment_intent_unexpected_state') unless CONFIRMABLE.include?(pi.status)
          return Outcome.error('resource_missing') unless known_card?(payment_method)

          pi.payment_method = payment_method
          decline = Policy::DECLINING_CARDS[payment_method]
          if decline
            pi.status = 'requires_payment_method'
            return Outcome.error(Policy::DECLINE_ERROR_CODES.fetch(decline, 'card_declined'), decline_code: decline)
          end

          # pm_card_timeout approves too: the acquirer committed, and Clearinghouse
          # finds that out through its status query instead of charging twice.
          if pi.capture_method == 'automatic'
            capture_funds(pi, pi.amount)
          else
            pi.status = 'requires_capture'
            pi.capturable = pi.amount
            pi.authorization_expires_at = @now + (Policy::AUTHORIZATION_TTL_DAYS * Policy::DAY)
          end
          intent_outcome(pi)
        end

        sig { override.params(intent: String, amount: T.nilable(Integer)).returns(Outcome) }
        def capture(intent:, amount: nil)
          pi = @intents[intent]
          return Outcome.error('resource_missing') unless pi
          return Outcome.error('payment_intent_unexpected_state') unless pi.status == 'requires_capture'

          return Outcome.error('payment_intent_authorization_expired') if @now >= T.must(pi.authorization_expires_at)

          amount ||= pi.capturable
          return Outcome.error('parameter_invalid') unless amount.positive? && amount <= pi.capturable
          return Outcome.error('amount_too_small') unless covers_fee?(pi.merchant, amount, pi.currency)

          capture_funds(pi, amount)
          intent_outcome(pi)
        end

        sig { override.params(intent: String).returns(Outcome) }
        def cancel(intent:)
          pi = @intents[intent]
          return Outcome.error('resource_missing') unless pi
          return Outcome.error('payment_intent_unexpected_state') unless CANCELABLE.include?(pi.status)

          pi.status = 'canceled'
          pi.capturable = 0
          intent_outcome(pi)
        end

        sig { override.params(refund: String, intent: String, amount: T.nilable(Integer)).returns(Outcome) }
        def refund(refund:, intent:, amount: nil)
          pi = @intents[intent]
          return Outcome.error('resource_missing') unless pi
          return Outcome.error('parameter_invalid') if @refunds.key?(refund)
          return Outcome.error('payment_intent_unexpected_state') unless pi.status == 'succeeded'
          # The acquirer refuses once the dispute has opened on its side, whether or
          # not Clearinghouse has processed the notification yet (docs/design/sim.md).
          return Outcome.error('charge_disputed') if disputed_at_acquirer?(pi)

          remaining = pi.received - pi.refunded
          return Outcome.error('charge_already_refunded') if remaining.zero?

          amount ||= remaining
          return Outcome.error('parameter_invalid') unless amount.positive? && amount <= remaining

          pi.refunded += amount
          @refunds[refund] = intent
          book(refund, :refund, pi.currency, amount, merchant: pi.merchant)
          schedule_movement(:refund, refund, pi.currency, amount, @now)
          Outcome.success(amount: amount, status: 'succeeded')
        end

        sig do
          override.params(payout: String, merchant: String, currency: String, amount: T.nilable(Integer))
                  .returns(Outcome)
        end
        def payout(payout:, merchant:, currency:, amount: nil)
          return Outcome.error('resource_missing') unless @merchants.key?(merchant)
          return Outcome.error('parameter_invalid') if @payouts.key?(payout)
          return Outcome.error('parameter_invalid') unless Policy::CURRENCIES.include?(currency)
          return Outcome.error('parameter_invalid') if amount && !amount.positive?

          # Blocked while the available balance is zero or negative, and never more
          # than is available. Held and pending funds are not available.
          available = available(merchant, currency)
          return Outcome.error('balance_insufficient') unless available.positive?

          amount ||= available
          return Outcome.error('balance_insufficient') if amount > available

          @payouts[payout] = PayoutState.new(name: payout, merchant: merchant, currency: currency, amount: amount,
                                             arrives_at: @now + Policy::PAYOUT_ARRIVAL_SECONDS)
          book(payout, :payout, currency, amount, merchant: merchant)
          Outcome.success(amount: amount, status: 'pending')
        end

        sig { override.params(hours: Integer).returns(Outcome) }
        def advance_clock(hours:)
          return Outcome.error('parameter_invalid') unless hours.positive?

          @now += hours * Policy::HOUR
          expire_authorizations
          deliver_notifications
          Outcome.success
        end

        sig { override.params(intent: String, outcome: String).returns(Outcome) }
        def resolve_dispute(intent:, outcome:)
          dispute = (name = @intents[intent]&.dispute) && @disputes[name]
          return Outcome.error('resource_missing') unless dispute
          return Outcome.error('parameter_invalid') unless %w[won lost].include?(outcome)
          return Outcome.error('dispute_not_open') if dispute.status == 'scheduled'
          return Outcome.error('dispute_already_closed') unless dispute.status == 'open'

          dispute.status = outcome
          if outcome == 'won'
            book(dispute.name, :dispute_won, dispute.currency, dispute.amount, merchant: dispute.merchant)
            schedule_movement(:dispute_reversal, dispute.name, dispute.currency, dispute.amount, @now)
          end
          Outcome.success(status: outcome)
        end

        # Reconciles the settlement file for today's date. The acquirer puts each
        # movement in the first file on or after its due date, so a skipped day's
        # lines arrive in the next file, and a second request for the same date
        # changes nothing.
        sig { override.returns(Outcome) }
        def settle
          today = @now.utc.to_date
          return Outcome.success if @settled_files.include?(today)

          @settled_files << today
          @movements.select { |m| !m.settled && m.due_on <= today }.each do |m|
            m.settled = true
            settle_movement(m)
          end
          Outcome.success
        end

        sig { override.returns(Outcome) }
        def availability_sweep
          @intents.each_value do |pi|
            next if pi.made_available || pi.available_on.nil? || T.must(pi.available_on) > @now

            pi.made_available = true
            net = pi.received - pi.fee
            book(pi.name, :funds_available, pi.currency, net, merchant: pi.merchant) if net.positive?
          end
          Outcome.success
        end

        # ---- inspection ----------------------------------------------------------

        sig { override.returns(Snapshot) }
        def snapshot
          Snapshot.new(
            balances: @balances.reject { |_, v| v.zero? },
            open_flows: open_flows,
            intents: @intents.values.select { |pi| pi.received.positive? }.to_h do |pi|
              [pi.name, IntentAmounts.new(captured: pi.received, refunded: pi.refunded)]
            end
          )
        end

        sig { returns(T::Hash[String, T::Hash[AccountKey, Integer]]) }
        def open_flows
          @flow_nets.transform_values { |nets| nets.reject { |_, v| v.zero? } }.reject { |_, nets| nets.empty? }
        end

        # Whether the domain says a flow is finished: nothing it started is still
        # waiting on the acquirer or the bank. A finished flow must hold no money in
        # clearing, and that is checked against the system under test without using
        # the model's balances.
        sig { params(flow_id: String).returns(T::Boolean) }
        def flow_complete?(flow_id)
          pending = @movements.any? { |m| m.flow_id == flow_id && !m.settled }
          return !pending if flow_id.start_with?('pi_', 're_')

          if flow_id.start_with?('dp_')
            dispute = @disputes[flow_id]
            return !pending && !dispute.nil? && %w[won lost].include?(dispute.status)
          end
          payout = @payouts[flow_id]
          payout.nil? || payout.status != 'pending'
        end

        private

        sig { params(merchant: String, amount: Integer, currency: String).returns(T::Boolean) }
        def covers_fee?(merchant, amount, currency)
          schedule = @merchants.fetch(merchant)
          Policy.covers_fee?(amount, schedule.fee_rate_scaled, schedule.fee_fixed.fetch(currency, 0))
        end

        # The expiry sweep: authorizations that waited too long for capture are
        # canceled. Nothing moves; the authorization lapses at the acquirer.
        sig { void }
        def expire_authorizations
          @intents.each_value do |payment|
            next unless payment.status == 'requires_capture' && T.must(payment.authorization_expires_at) <= @now

            payment.status = 'canceled'
            payment.capturable = 0
          end
        end

        sig { params(card: String).returns(T::Boolean) }
        def known_card?(card)
          Policy::APPROVING_CARDS.include?(card) || Policy::DECLINING_CARDS.key?(card)
        end

        sig { params(payment: IntentState).returns(Outcome) }
        def intent_outcome(payment)
          Outcome.success(status: payment.status, amount_received: payment.received)
        end

        sig { params(payment: IntentState).returns(T::Boolean) }
        def disputed_at_acquirer?(payment)
          dispute = payment.dispute && @disputes[T.must(payment.dispute)]
          !dispute.nil? && dispute.opens_at <= @now
        end

        sig { params(payment: IntentState, amount: Integer).void }
        def capture_funds(payment, amount)
          merchant = @merchants.fetch(payment.merchant)
          payment.status = 'succeeded'
          payment.capturable = 0
          payment.received = amount
          payment.fee = Policy.fee(amount, merchant.fee_rate_scaled, merchant.fee_fixed.fetch(payment.currency, 0))
          payment.available_on = @now + (Policy::PAYOUT_DELAY_DAYS * Policy::DAY)
          book(payment.name, :capture, payment.currency, amount, merchant: payment.merchant)
          schedule_movement(:capture, payment.name, payment.currency, amount, @now)
          return unless payment.payment_method == Policy::DISPUTING_CARD

          # The simulator fixes the disputed amount at capture; later refunds do not
          # shrink it.
          name = payment.name.sub(/\Api_/, 'dp_')
          payment.dispute = name
          @disputes[name] = DisputeState.new(
            name: name, intent: payment.name, merchant: payment.merchant, currency: payment.currency, amount: amount,
            fee: Policy::DISPUTE_FEE.fetch(payment.currency), opens_at: @now + (Policy::DISPUTE_AFTER_DAYS * Policy::DAY)
          )
        end

        sig { params(kind: Symbol, flow_id: String, currency: String, amount: Integer, at: Time).void }
        def schedule_movement(kind, flow_id, currency, amount, at)
          @movements << Movement.new(kind: kind, flow_id: flow_id, currency: currency, amount: amount,
                                     due_on: at.utc.to_date + Policy::SETTLEMENT_LAG_DAYS)
        end

        # Notifications fall due at their own times and are delivered in that order.
        sig { void }
        def deliver_notifications
          due = @disputes.values.select { |d| d.status == 'scheduled' && d.opens_at <= @now }
                         .map { |d| [d.opens_at, 0, d.name] } +
                @payouts.values.select { |p| p.status == 'pending' && p.arrives_at <= @now }
                        .map { |p| [p.arrives_at, 1, p.name] }
          due.sort.each do |_, kind, name|
            kind.zero? ? open_dispute(@disputes.fetch(name)) : finish_payout(@payouts.fetch(name))
          end
        end

        sig { params(dispute: DisputeState).void }
        def open_dispute(dispute)
          dispute.status = 'open'
          book(dispute.name, :dispute_opened, dispute.currency, dispute.amount, merchant: dispute.merchant,
                                                                                fee: dispute.fee)
          schedule_movement(:dispute, dispute.name, dispute.currency, dispute.amount, dispute.opens_at)
        end

        sig { params(payout: PayoutState).void }
        def finish_payout(payout)
          if Policy.payout_fails?(payout.amount)
            payout.status = 'failed'
            book(payout.name, :payout_failed, payout.currency, payout.amount, merchant: payout.merchant)
          else
            payout.status = 'paid'
            book(payout.name, :payout_paid, payout.currency, payout.amount)
          end
        end

        sig { params(movement: Movement).void }
        def settle_movement(movement)
          kind = { capture: :settlement, refund: :refund_settled, dispute: :dispute_debited,
                   dispute_reversal: :dispute_funds_returned }.fetch(movement.kind)
          book(movement.flow_id, kind, movement.currency, movement.amount)
        end

        # Records the event and books the model's own entries for it: the money-flow
        # table of docs/design/ledger.md, one row per event kind.
        sig do
          params(flow_id: String, kind: Symbol, currency: String, amount: Integer, merchant: T.nilable(String),
                 fee: Integer).void
        end
        def book(flow_id, kind, currency, amount, merchant: nil, fee: 0)
          @events << Event.new(kind: kind, flow_id: flow_id, currency: currency, amount: amount, merchant: merchant,
                               fee: fee)
          entries(flow_id, kind, amount, merchant, fee).each do |account, side, value|
            post(flow_id, account, side, value, currency)
          end
        end

        # rubocop:disable Metrics/CyclomaticComplexity
        sig do
          params(flow_id: String, kind: Symbol, amount: Integer, merchant: T.nilable(String), fee: Integer)
            .returns(T::Array[[String, Symbol, Integer]])
        end
        def entries(flow_id, kind, amount, merchant, fee)
          pending = "merchant:#{merchant}:pending"
          available = "merchant:#{merchant}:available"
          case kind
          when :capture
            our_fee = @intents.fetch(flow_id).fee
            [[RECEIVABLE, :debit, amount], [pending, :credit, amount - our_fee], [FEE_REVENUE, :credit, our_fee]]
          when :settlement
            acquirer_fee = Policy.acquirer_fee(amount)
            [[CASH, :debit, amount - acquirer_fee], [PROCESSING_EXPENSE, :debit, acquirer_fee],
             [RECEIVABLE, :credit, amount]]
          when :funds_available then [[pending, :debit, amount], [available, :credit, amount]]
          when :refund then [[available, :debit, amount], [REFUND_CLEARING, :credit, amount]]
          when :refund_settled then [[REFUND_CLEARING, :debit, amount], [CASH, :credit, amount]]
          when :dispute_opened
            [[available, :debit, amount + fee], [DISPUTE_CLEARING, :credit, amount],
             [DISPUTE_FEE_REVENUE, :credit, fee]]
          when :dispute_debited then [[DISPUTE_CLEARING, :debit, amount], [CASH, :credit, amount]]
          when :dispute_won then [[DISPUTE_CLEARING, :debit, amount], [available, :credit, amount]]
          when :dispute_funds_returned then [[CASH, :debit, amount], [DISPUTE_CLEARING, :credit, amount]]
          when :payout then [[available, :debit, amount], [PAYOUT_CLEARING, :credit, amount]]
          when :payout_paid then [[PAYOUT_CLEARING, :debit, amount], [CASH, :credit, amount]]
          when :payout_failed then [[PAYOUT_CLEARING, :debit, amount], [available, :credit, amount]]
          else raise ArgumentError, "no entries for #{kind}"
          end
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        sig { params(flow_id: String, account: String, side: Symbol, value: Integer, currency: String).void }
        def post(flow_id, account, side, value, currency)
          normal = DEBIT_NORMAL.include?(account) ? :debit : :credit
          signed = side == normal ? value : -value
          key = [account, currency]
          @balances[key] = @balances.fetch(key, 0) + signed
          return unless CLEARING.include?(account)

          nets = (@flow_nets[flow_id] ||= {})
          nets[key] = nets.fetch(key, 0) + signed
        end
      end
    end
  end
end
