# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Balances
    # Risk-review holds: the "safer payouts" half of M6. When RiskGate answers
    # `review` for a payment, the payment still goes through, but its money must not
    # reach the merchant's bank until someone has looked at it. A hold does that by
    # routing the payment's net to the merchant's held account instead of available.
    # Payouts only ever spend available, so held money cannot be paid out.
    #
    #   open     : the availability sweep sends the net to held (pending -> held);
    #              if it was already available, open_hold! moves it (available -> held)
    #   approve  : held -> available, or nothing yet if the sweep has not run
    #   reject   : the payment is refunded; the held money goes back to available in
    #              the refund's own transaction (release_after_refund!, just before
    #              the refund takes the refunded amount out of available)
    #
    # Lock order, everywhere: the payment's scheduled_availabilities row first, then
    # its risk_holds row, then balance rows in account id order. The sweep takes
    # them in that order too.
    module Holds
      extend T::Sig

      TABLE = :risk_holds

      # A hold, as stored. `open?` until closed with a resolution.
      class Hold < T::Struct
        extend T::Sig

        const :id, String
        const :flow_id, String
        const :merchant_id, String
        const :amount, Money
        const :reason, String
        const :opened_at, Time
        const :closed_at, T.nilable(Time)
        const :resolution, T.nilable(String)
        const :held_amount, Integer
        const :refund_id, T.nilable(String)
        const :refund_applied_at, T.nilable(Time)

        sig { returns(T::Boolean) }
        def open?
          closed_at.nil?
        end

        # Stripe's Review object, trimmed to what Clearinghouse has. `reason` is
        # why RiskGate sent it to review; `closed_reason` says how it ended.
        sig { returns(T::Hash[String, T.untyped]) }
        def to_api
          {
            'id' => id, 'object' => 'review', 'payment_intent' => flow_id, 'amount' => amount.amount,
            'currency' => amount.currency, 'open' => open?, 'opened_reason' => 'rule', 'reason' => reason,
            'closed_reason' => { 'approved' => 'approved', 'rejected' => 'refunded_as_fraud' }[resolution],
            'created' => opened_at.to_i, 'closed' => closed_at&.to_i, 'livemode' => false
          }
        end
      end

      class Error < Clearinghouse::Error; end
      class NotFoundError < Error; end
      # Approve or reject on a review that is already closed.
      class AlreadyClosedError < Error; end

      RESOLUTIONS = T.let({ approve: 'approved', reject: 'rejected' }.freeze, T::Hash[Symbol, String])

      # Opens a hold on a payment. Called by the risk integration when RiskGate says
      # `review`, normally during confirm, before the capture has scheduled anything.
      # Idempotent on the payment: a second call returns the first hold.
      sig do
        params(db: Sequel::Database, flow_id: String, merchant_id: String, amount: Money, reason: String,
               clock: Clock, events: EventSink).returns(Hold)
      end
      def self.open_hold!(db, flow_id:, merchant_id:, amount:, reason:, clock:, events: DEFAULT_EVENTS)
        T.let(db.transaction do
          scheduled = Availability.find_for_update(db, flow_id)
          values = [Ids.generate('prv'), flow_id, merchant_id, amount.amount, amount.currency, reason, clock.now]
          row = db.fetch(<<~SQL, *values).first
            INSERT INTO risk_holds (id, flow_id, merchant_id, amount, currency, reason, opened_at)
            VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (flow_id) DO NOTHING RETURNING *
          SQL
          if row
            if scheduled && scheduled.released_to == 'available'
              row = withhold_available(db, from_row(row), scheduled, clock)
            end
            hold = from_row(row)
            events.emit!(db, merchant_id: merchant_id, type: 'review.opened', object: hold.to_api, clock: clock)
            hold
          else
            T.must(find(db, flow_id: flow_id))
          end
        end, Hold)
      end

      # Closes an open hold. `approve` releases whatever the hold has in held.
      # `reject` starts a refund of the payment through `refunds` and releases
      # nothing: the money stays held until that refund calls
      # release_after_refund! in the transaction that posts it.
      sig do
        params(db: Sequel::Database, id: String, merchant_id: String, decision: Symbol, clock: Clock,
               events: EventSink, refunds: RefundRequester).returns(Hold)
      end
      def self.close_hold!(db, id, merchant_id:, decision:, clock:, events: DEFAULT_EVENTS, refunds: DEFAULT_REFUNDS)
        resolution = RESOLUTIONS.fetch(decision) { raise ArgumentError, 'decision must be :approve or :reject' }
        T.let(db.transaction do
          hold = locked(db, find(db, id: id, merchant_id: merchant_id) || raise(NotFoundError, "no review #{id}"))
          raise AlreadyClosedError, "review #{id} is already closed (#{hold.resolution})" unless hold.open?

          changes = T.let({ closed_at: clock.now, resolution: resolution }, T::Hash[Symbol, T.untyped])
          if resolution == 'approved'
            release_held(db, hold, clock)
            changes[:held_amount] = 0
          else
            changes[:refund_id] = refunds.request_refund!(db, payment_intent_id: hold.flow_id, reason: 'fraudulent',
                                                              clock: clock)
          end
          closed = update!(db, hold.id, changes)
          events.emit!(db, merchant_id: merchant_id, type: 'review.closed', object: closed.to_api, clock: clock)
          closed
        end, Hold)
      end

      # Called by the refund of a payment, in the transaction that posts the refund's
      # ledger entries, *before* it posts them, with those entries. If the payment's
      # review was rejected, moves its held money back to available, where the
      # refund is about to debit the same amount. Idempotent, and a no-op for a
      # payment with no rejected hold. Returns the hold, if there is one.
      #
      # Why before: this locks the payment's availability row, and the sweep holds
      # that row while it takes balance locks. A refund that had already posted
      # would hold `available` while waiting for the row. And the two postings lock
      # held, available and refund_clearing up front, in account id order
      # (Ledger.lock_balances!), so they cannot take them in an order a concurrent
      # approval or refund does not.
      sig do
        params(db: Sequel::Database, flow_id: String, clock: Clock,
               refund_entries: T::Array[Ledger::Entry]).returns(T.nilable(Hold))
      end
      def self.release_after_refund!(db, flow_id:, clock:, refund_entries:)
        T.let(db.transaction do
          hold = find(db, flow_id: flow_id)
          next hold unless hold && hold.resolution == 'rejected' && hold.refund_applied_at.nil?

          hold = locked(db, hold)
          next hold unless hold.refund_applied_at.nil?

          release_held(db, hold, clock, also_locking: refund_entries)
          update!(db, hold.id, { refund_applied_at: clock.now, held_amount: 0 })
        end, T.nilable(Hold))
      end

      # Whether a payment's money must be kept out of available right now: its
      # review is open, or it was rejected and the refund has not taken the money
      # yet. The availability sweep asks this for every release.
      sig { params(db: Sequel::Database, flow_id: String).returns(T::Boolean) }
      def self.withholds?(db, flow_id)
        hold = find(db, flow_id: flow_id)
        return false unless hold

        hold.open? || (hold.resolution == 'rejected' && hold.refund_applied_at.nil?)
      end

      # The availability sweep sent this payment's net to held. Runs in the sweep's
      # transaction, which already holds the availability row's lock.
      sig { params(db: Sequel::Database, flow_id: String, net: Money).void }
      def self.record_held!(db, flow_id, net)
        updated = db[TABLE].where(flow_id: flow_id).update(held_amount: Sequel[:held_amount] + net.amount)
        raise Error, "no hold for #{flow_id}" unless updated == 1
      end

      sig do
        params(db: Sequel::Database, id: T.nilable(String), flow_id: T.nilable(String),
               merchant_id: T.nilable(String)).returns(T.nilable(Hold))
      end
      def self.find(db, id: nil, flow_id: nil, merchant_id: nil)
        scope = db[TABLE]
        scope = scope.where(id: id) if id
        scope = scope.where(flow_id: flow_id) if flow_id
        scope = scope.where(merchant_id: merchant_id) if merchant_id
        row = scope.first
        row ? from_row(row) : nil
      end

      # Newest first, optionally only open or only closed ones.
      sig do
        params(db: Sequel::Database, merchant_id: String, limit: Integer, starting_after: T.nilable(String),
               open: T.nilable(T::Boolean)).returns([T::Array[Hold], T::Boolean])
      end
      def self.list(db, merchant_id:, limit: 10, starting_after: nil, open: nil)
        scope = db[TABLE].where(merchant_id: merchant_id)
        scope = open ? scope.where(closed_at: nil) : scope.exclude(closed_at: nil) unless open.nil?
        if starting_after
          cursor = db[TABLE].where(id: starting_after, merchant_id: merchant_id).select(:opened_at, :id).first
          raise NotFoundError, "no review #{starting_after}" unless cursor

          scope = scope.where(Sequel.lit('(opened_at, id) < (?, ?)', cursor.fetch(:opened_at), cursor.fetch(:id)))
        end
        rows = scope.order(Sequel.desc(:opened_at), Sequel.desc(:id)).limit(limit + 1).all
        [rows.first(limit).map { |row| from_row(row) }, rows.length > limit]
      end

      # Locks the payment's availability row and then the hold row (the lock
      # order in the module comment) and returns the hold as it is now.
      sig { params(db: Sequel::Database, hold: Hold).returns(Hold) }
      def self.locked(db, hold)
        Availability.find_for_update(db, hold.flow_id)
        from_row(db[TABLE].where(id: hold.id).for_update.first)
      end
      private_class_method :locked

      # `also_locking` are the entries of another posting this transaction will
      # make next; their balance rows are locked with the release's, in one order.
      sig { params(db: Sequel::Database, hold: Hold, clock: Clock, also_locking: T::Array[Ledger::Entry]).void }
      def self.release_held(db, hold, clock, also_locking: [])
        return if hold.held_amount.zero?

        entries = Ledger::Flows.hold_released(merchant_id: hold.merchant_id,
                                              amount: Money.of(hold.held_amount, hold.amount.currency))
        Ledger.lock_balances!(db, Ledger.accounts_of(entries + also_locking)) unless also_locking.empty?
        Ledger.post!(db, flow_type: Ledger::Flows::PAYMENT, flow_id: hold.flow_id, description: 'hold released',
                         effective_at: clock.now, entries: entries)
      end
      private_class_method :release_held

      # A review opened after the sweep already made the money available. It moves
      # back to held, even if that takes available negative: a payout that already
      # spent it is the negative-balance case, and payouts stop until it is repaid.
      sig do
        params(db: Sequel::Database, hold: Hold, scheduled: Availability::Scheduled,
               clock: Clock).returns(T::Hash[Symbol, T.untyped])
      end
      def self.withhold_available(db, hold, scheduled, clock)
        Ledger.post!(db, flow_type: Ledger::Flows::PAYMENT, flow_id: hold.flow_id, description: 'funds withheld',
                         effective_at: clock.now,
                         entries: Ledger::Flows.funds_withheld(merchant_id: hold.merchant_id, amount: scheduled.net))
        db[TABLE].where(id: hold.id).returning.update(held_amount: scheduled.net.amount).fetch(0)
      end
      private_class_method :withhold_available

      sig { params(db: Sequel::Database, id: String, changes: T::Hash[Symbol, T.untyped]).returns(Hold) }
      def self.update!(db, id, changes)
        from_row(db[TABLE].where(id: id).returning.update(changes).fetch(0))
      end
      private_class_method :update!

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(Hold) }
      def self.from_row(row)
        Hold.new(id: row.fetch(:id), flow_id: row.fetch(:flow_id), merchant_id: row.fetch(:merchant_id),
                 amount: Money.of(Integer(row.fetch(:amount)), row.fetch(:currency)), reason: row.fetch(:reason),
                 opened_at: row.fetch(:opened_at).utc, closed_at: row[:closed_at]&.utc, resolution: row[:resolution],
                 held_amount: Integer(row.fetch(:held_amount)), refund_id: row[:refund_id],
                 refund_applied_at: row[:refund_applied_at]&.utc)
      end
      private_class_method :from_row
    end
  end
end
