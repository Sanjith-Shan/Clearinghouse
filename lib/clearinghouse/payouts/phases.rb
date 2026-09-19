# typed: strict
# frozen_string_literal: true

module Clearinghouse
  # Creating a payout, one atomic phase per method.
  #
  # POST /v1/payouts runs these as the idempotency framework's phases
  # (Payouts::Flows::Create). They also stand on their own, with the payout row
  # carrying its recovery point, because automatic payouts are made by a sweep
  # with no request and no key: `drive!` resumes a payout from wherever a crash
  # left it and `resume_incomplete!` finds the stopped ones. docs/design/payouts.md
  # has the crash matrix.
  #
  #   started           -> reserve!       -> balance_reserved   (one DB transaction)
  #   balance_reserved  -> request_bank!  -> bank_requested     (one DB transaction)
  #   bank_requested    -> call_bank      (the foreign call, no transaction)
  #   bank_requested    -> record_bank!   -> bank_recorded      (one DB transaction)
  #   bank_recorded     -> (response stored by the framework) -> finished
  module Payouts
    extend T::Sig

    # How long a payout may sit mid-request before resume_incomplete! assumes its
    # request died. Racing a live request is safe (the phases re-check the recovery
    # point under a row lock, and the bank dedupes the key); this only avoids
    # doing it for no reason.
    STALE_AFTER_SECONDS = 60

    # Phase 1, started -> balance_reserved. Locks the merchant's available balance
    # row (Ledger.balance_for_update), so two payouts, or a payout and a dispute,
    # cannot both spend the same money: the second waits for the first to commit
    # and then sees the lower balance. Refuses while available is zero or negative
    # (the negative-balance policy in docs/design/ledger.md). `amount` nil means the
    # whole available balance. `scheduled_for` marks an automatic payout, and a
    # second one for the same merchant, currency and day returns the first.
    sig do
      params(db: Sequel::Database, merchant_id: String, currency: String, clock: Clock, amount: T.nilable(Integer),
             description: T.nilable(String), metadata: T::Hash[String, String], scheduled_for: T.nilable(Date),
             events: Balances::EventSink).returns(Payout)
    end
    def self.reserve!(db, merchant_id:, currency:, clock:, amount: nil, description: nil, metadata: {},
                      scheduled_for: nil, events: Balances::DEFAULT_EVENTS)
      raise ArgumentError, "payout amount must be positive, got #{amount}" if amount && amount <= 0

      currency = Currency.normalize(currency)
      T.let(db.transaction do
        available = Ledger.balance_for_update(db, available_account(merchant_id), currency)
        existing = scheduled_for && db[:payouts].where(merchant_id: merchant_id, currency: currency,
                                                       scheduled_for: scheduled_for, automatic: true).first
        if existing
          from_row(existing)
        else
          requested = amount ? Money.of(amount, currency) : nil
          raise BalanceInsufficientError.new(available, requested) unless available.positive?
          raise BalanceInsufficientError.new(available, requested) if requested && requested > available

          insert_reserved(db, merchant_id: merchant_id, amount: requested || available, clock: clock,
                              description: description, metadata: metadata, scheduled_for: scheduled_for,
                              events: events)
        end
      end, Payout)
    end

    # Phase 2, balance_reserved -> bank_requested. Fixes the bank idempotency key
    # and commits it *before* the call, so whatever happens to the call, a retry
    # asks the bank about this key rather than sending under a new one. A payout is
    # sent to the bank at most once (a failure is terminal and the merchant makes a
    # new payout), so one key per payout is one key per attempt.
    sig { params(db: Sequel::Database, payout_id: String, clock: Clock).returns(Payout) }
    def self.request_bank!(db, payout_id, clock:)
      T.let(db.transaction do
        row = lock!(db, payout_id)
        if row.fetch(:status) == 'pending' && row.fetch(:recovery_point) == 'balance_reserved'
          row = update!(db, payout_id, clock, recovery_point: 'bank_requested',
                                              bank_idempotency_key: "#{payout_id}:bank")
        end
        from_row(row)
      end, Payout)
    end

    # The foreign call. On a first attempt it sends. On a resume it first asks the
    # bank what it did under the key, because the previous call may have gone
    # through with its answer lost (Unknown), and only sends if the answer is
    # "nothing" (NotFound). Resending under the same key would also be safe with
    # this bank, which replays a repeated key, but asking first does not depend on that.
    sig do
      params(bank: Acquirer::Client, payout: Payout, resuming: T::Boolean)
        .returns(T.any(Acquirer::Approved, Acquirer::Declined, Acquirer::Unknown, Acquirer::Unavailable))
    end
    def self.call_bank(bank, payout, resuming:)
      key = T.must(payout.bank_idempotency_key)
      if resuming
        found = bank.lookup(key)
        return found unless found.is_a?(Acquirer::NotFound)
      end
      bank.payout(reference: payout.id, merchant_id: payout.merchant_id, amount: payout.amount, idempotency_key: key)
    end

    # Phase 3, bank_requested -> bank_recorded. Approved puts the payout in transit;
    # Declined fails it and returns the money to available in the same transaction.
    # Unknown and Unavailable record nothing: the payout stays at bank_requested and
    # the next drive! asks the bank before doing anything else.
    sig do
      params(db: Sequel::Database, payout_id: String,
             outcome: T.any(Acquirer::Approved, Acquirer::Declined, Acquirer::Unknown, Acquirer::Unavailable),
             clock: Clock, events: Balances::EventSink).returns(Payout)
    end
    def self.record_bank!(db, payout_id, outcome, clock:, events: Balances::DEFAULT_EVENTS)
      T.let(db.transaction do
        row = lock!(db, payout_id)
        if row.fetch(:recovery_point) == 'bank_requested' && !outcome.is_a?(Acquirer::Unknown) &&
           !outcome.is_a?(Acquirer::Unavailable)
          row = apply_bank_answer(db, from_row(row), outcome, clock, events)
        end
        from_row(row)
      end, Payout)
    end

    # Runs whatever phases are left, from the recovery point on the row. The one
    # entry point for a new payout, a retried request and the resume sweep.
    sig do
      params(db: Sequel::Database, payout_id: String, bank: Acquirer::Client, clock: Clock,
             events: Balances::EventSink).returns(Payout)
    end
    def self.drive!(db, payout_id, bank:, clock:, events: Balances::DEFAULT_EVENTS)
      payout = find(db, payout_id) || raise(NotFoundError, "no payout #{payout_id}")
      resuming = payout.recovery_point == 'bank_requested'
      payout = request_bank!(db, payout_id, clock: clock) if payout.recovery_point == 'balance_reserved'
      return payout unless payout.status == 'pending' && payout.recovery_point == 'bank_requested'

      record_bank!(db, payout_id, call_bank(bank, payout, resuming: resuming), clock: clock, events: events)
    end

    # reserve! then drive!: what POST /v1/payouts does.
    sig do
      params(db: Sequel::Database, merchant_id: String, currency: String, bank: Acquirer::Client, clock: Clock,
             amount: T.nilable(Integer), description: T.nilable(String), metadata: T::Hash[String, String],
             events: Balances::EventSink).returns(Payout)
    end
    def self.create!(db, merchant_id:, currency:, bank:, clock:, amount: nil, description: nil, metadata: {},
                     events: Balances::DEFAULT_EVENTS)
      payout = reserve!(db, merchant_id: merchant_id, currency: currency, clock: clock, amount: amount,
                            description: description, metadata: metadata, events: events)
      drive!(db, payout.id, bank: bank, clock: clock, events: events)
    end

    # Cancels a payout that has not gone to the bank yet (the bank was unavailable
    # and it is waiting to be resent). The reservation is reversed, so the money is
    # back in available in the same transaction that marks the payout canceled.
    sig do
      params(db: Sequel::Database, payout_id: String, merchant_id: String, clock: Clock,
             events: Balances::EventSink).returns(Payout)
    end
    def self.cancel!(db, payout_id, merchant_id:, clock:, events: Balances::DEFAULT_EVENTS)
      T.let(db.transaction do
        row = db[:payouts].where(id: payout_id, merchant_id: merchant_id).for_update.first
        raise NotFoundError, "no payout #{payout_id}" unless row

        unless row.fetch(:status) == 'pending' && row.fetch(:recovery_point) == 'balance_reserved'
          detail = row.fetch(:status) == 'pending' ? 'has already been sent to the bank' : "is #{row.fetch(:status)}"
          raise NotCancelableError, "payout #{payout_id} #{detail}"
        end

        Ledger.reverse!(db, Integer(row.fetch(:reserve_transaction_id)), reason: 'payout canceled',
                                                                         effective_at: clock.now)
        payout = from_row(update!(db, payout_id, clock, status: 'canceled'))
        events.emit!(db, merchant_id: merchant_id, type: 'payout.canceled', object: payout.to_api, clock: clock)
        payout
      end, Payout)
    end

    # Drives every payout that stopped mid-way (a crash, or the bank unavailable
    # or silent) and has not been touched for STALE_AFTER_SECONDS. Automatic
    # payouts have no idempotency key, so this is what finishes them. For an API
    # payout it races the framework's completer, which is safe: the phases
    # re-check the recovery point under the row lock and the bank dedupes the key.
    sig do
      params(db: Sequel::Database, bank: Acquirer::Client, clock: Clock, events: Balances::EventSink,
             stale_after: Integer).returns(T::Array[Payout])
    end
    def self.resume_incomplete!(db, bank:, clock:, events: Balances::DEFAULT_EVENTS, stale_after: STALE_AFTER_SECONDS)
      ids = db[:payouts].where(status: 'pending', recovery_point: %w[balance_reserved bank_requested])
                        .where(Sequel.lit('updated_at <= ?', clock.now - stale_after)).order(:updated_at)
                        .select_map(:id)
      ids.map { |id| drive!(db, id, bank: bank, clock: clock, events: events) }
    end

    sig do
      params(db: Sequel::Database, merchant_id: String, amount: Money, clock: Clock, description: T.nilable(String),
             metadata: T::Hash[String, String], scheduled_for: T.nilable(Date),
             events: Balances::EventSink).returns(Payout)
    end
    def self.insert_reserved(db, merchant_id:, amount:, clock:, description:, metadata:, scheduled_for:, events:)
      id = Ids.generate('po')
      now = clock.now
      txn = Ledger.post!(db, flow_type: Ledger::Flows::PAYOUT, flow_id: id, description: 'payout', effective_at: now,
                             entries: Ledger::Flows.payout(merchant_id: merchant_id, amount: amount))
      row = db[:payouts].returning.insert(
        id: id, merchant_id: merchant_id, amount: amount.amount, currency: amount.currency, status: 'pending',
        recovery_point: 'balance_reserved', automatic: !scheduled_for.nil?, scheduled_for: scheduled_for,
        description: description, metadata: JSON.generate(metadata), reserve_transaction_id: txn,
        arrival_date: now + Clock::SECONDS_PER_DAY, created_at: now, updated_at: now
      ).fetch(0)
      payout = from_row(row)
      events.emit!(db, merchant_id: merchant_id, type: 'payout.created', object: payout.to_api, clock: clock)
      payout
    end
    private_class_method :insert_reserved

    sig do
      params(db: Sequel::Database, payout: Payout, outcome: T.any(Acquirer::Approved, Acquirer::Declined),
             clock: Clock, events: Balances::EventSink).returns(T::Hash[Symbol, T.untyped])
    end
    def self.apply_bank_answer(db, payout, outcome, clock, events)
      # Only reached at bank_requested, where the status is still pending: a
      # notification that overtakes a stalled request moves it to bank_recorded.
      reference = outcome.operation.acquirer_reference
      if outcome.is_a?(Acquirer::Approved)
        return update!(db, payout.id, clock, recovery_point: 'bank_recorded', status: 'in_transit',
                                             acquirer_reference: reference)
      end

      Ledger.post!(db, flow_type: Ledger::Flows::PAYOUT, flow_id: payout.id, description: 'payout failed',
                       effective_at: clock.now,
                       entries: Ledger::Flows.payout_failed(merchant_id: payout.merchant_id, amount: payout.amount))
      row = update!(db, payout.id, clock, recovery_point: 'bank_recorded', status: 'failed',
                                          failure_code: outcome.code, acquirer_reference: reference)
      events.emit!(db, merchant_id: payout.merchant_id, type: 'payout.failed', object: from_row(row).to_api,
                       clock: clock)
      row
    end
    private_class_method :apply_bank_answer

    sig { params(db: Sequel::Database, payout_id: String).returns(T::Hash[Symbol, T.untyped]) }
    def self.lock!(db, payout_id)
      db[:payouts].where(id: payout_id).for_update.first || raise(NotFoundError, "no payout #{payout_id}")
    end
    private_class_method :lock!

    sig do
      params(db: Sequel::Database, payout_id: String, clock: Clock,
             changes: T.untyped).returns(T::Hash[Symbol, T.untyped])
    end
    def self.update!(db, payout_id, clock, **changes)
      db[:payouts].where(id: payout_id).returning.update(**changes, updated_at: clock.now).fetch(0)
    end
    private_class_method :update!
  end
end
