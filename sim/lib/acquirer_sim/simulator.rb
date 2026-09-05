# typed: true
# frozen_string_literal: true

module AcquirerSim
  # The acquirer's books: every operation by idempotency key and every authorization
  # by acquirer reference, in memory behind one mutex. The HTTP layer (App) parses a
  # request and hands it here; everything that decides an outcome or changes state
  # happens inside #submit under the lock, so two concurrent requests with one key
  # cannot both commit.
  class Simulator
    extend T::Sig

    # What a test token does at authorization. Anything not listed is a 400.
    class Token < T::Struct
      const :decline_code, T.nilable(String)
      # Commit the authorization, then close the connection without answering.
      const :timeout, T::Boolean, default: false
      # Approve, and open a fraudulent dispute dispute_after_days after capture.
      const :dispute, T::Boolean, default: false
    end

    TOKENS = T.let(
      {
        'pm_card_visa' => Token.new,
        'pm_card_mastercard' => Token.new,
        'pm_card_chargeDeclined' => Token.new(decline_code: 'generic_decline'),
        'pm_card_insufficientFunds' => Token.new(decline_code: 'insufficient_funds'),
        'pm_card_expired' => Token.new(decline_code: 'expired_card'),
        'pm_card_timeout' => Token.new(timeout: true),
        'pm_card_disputeFraudulent' => Token.new(dispute: true)
      }.freeze,
      T::Hash[String, Token]
    )

    # Route name to operation type.
    MUTATIONS = T.let(
      { 'authorize' => 'authorize', 'capture' => 'capture', 'void' => 'void', 'refund' => 'refund',
        'payouts' => 'payout' }.freeze,
      T::Hash[String, String]
    )

    # The documented, deterministic payout failure: an amount whose last two digits
    # are 13 (in minor units, so $10.13, or 1013 yen) fails with account_closed. It
    # is a rule on the amount because Clearinghouse chooses payout amounts in tests
    # but not merchant ids, which it generates.
    PAYOUT_FAILURE_CODE = 'account_closed'

    sig { params(amount: Integer).returns(T::Boolean) }
    def self.payout_fails?(amount)
      amount % 100 == 13
    end

    # One mutating request on its way through #submit.
    class Submission < T::Struct
      const :type, String
      const :key, String
      const :fingerprint, String
      const :params, T::Hash[String, T.untyped]
      const :sim_time, Time
    end

    # The outcome of #submit. `replayed` is true when the key had already committed
    # and this is the stored operation coming back. `drop_connection` asks the HTTP
    # layer to hang up instead of answering; it is only ever set on a fresh commit,
    # so a retry of the same key gets its answer.
    class Result < T::Struct
      const :operation, Operation
      const :replayed, T::Boolean
      const :drop_connection, T::Boolean, default: false
    end

    sig { returns(Config) }
    attr_reader :config

    sig { params(config: Config).void }
    def initialize(config: Config.new)
      @mutex = T.let(Mutex.new, Thread::Mutex)
      @config = config
      @traffic = T.let(Traffic.new(config), Traffic)
      @operations = T.let({}, T::Hash[String, Operation])
      @authorizations = T.let({}, T::Hash[String, Authorization])
      @disputes = T.let({}, T::Hash[String, Dispute])
      @payouts = T.let({}, T::Hash[String, Payout])
      @notifications = T.let(Notifications.new, Notifications)
      @settlement = T.let(Settlement.new, Settlement)
    end

    # Commits one mutating request, or replays the stored operation for its key.
    # Validation failures raise RequestError before anything is recorded, so a
    # malformed request never burns its idempotency key.
    sig { params(type: String, key: String, params: T::Hash[String, T.untyped], sim_time: Time).returns(Result) }
    def submit(type, key, params, sim_time)
      raise ArgumentError, "unknown operation type #{type}" unless MUTATIONS.value?(type)

      fingerprint = Params.fingerprint(type, params)
      @mutex.synchronize do
        existing = @operations[key]
        return replay(existing, fingerprint) if existing

        request = Submission.new(type: type, key: key, fingerprint: fingerprint, params: params, sim_time: sim_time)
        operation =
          case type
          when 'authorize' then do_authorize(request)
          when 'capture' then do_capture(request)
          when 'void' then do_void(request)
          when 'refund' then do_refund(request)
          else do_payout(request)
          end
        @operations[key] = operation
        Result.new(operation: operation, replayed: false, drop_connection: drop_after_commit?(request))
      end
    end

    # How the network misbehaves for the next request. See Traffic.
    sig { returns(Traffic::Decision) }
    def traffic_decision
      @mutex.synchronize { @traffic.decide }
    end

    # Replaces the config with `json` merged over it. A new seed restarts the traffic
    # RNG, so `configure(seed: n)` followed by a fixed request sequence is repeatable.
    sig { params(json: T::Hash[String, T.untyped]).returns(Config) }
    def configure(json)
      @mutex.synchronize do
        @config = Config.merge(json, @config)
        @traffic = Traffic.new(@config)
        @config
      end
    end

    sig { params(key: String).returns(T.nilable(Operation)) }
    def operation(key)
      @mutex.synchronize { @operations[key] }
    end

    sig { returns(T::Array[Operation]) }
    def operations
      @mutex.synchronize { @operations.values }
    end

    sig { returns(T::Array[Authorization]) }
    def authorizations
      @mutex.synchronize { @authorizations.values.map(&:dup) }
    end

    sig { returns(T::Array[Dispute]) }
    def disputes
      @mutex.synchronize { @disputes.values.map(&:dup) }
    end

    sig { returns(T::Array[Payout]) }
    def payouts
      @mutex.synchronize { @payouts.values }
    end

    # Notifications visible at `sim_time` past the cursor `after`. See Notifications.
    sig { params(after: Integer, sim_time: Time, limit: Integer).returns(Notifications::Page) }
    def notifications(after:, sim_time:, limit: Notifications::DEFAULT_LIMIT)
      @mutex.synchronize { @notifications.page(after: after, sim_time: sim_time, limit: limit) }
    end

    # Closes an open dispute, as the card network would after the evidence round.
    # The dispute.closed notification is due at the request's Sim-Time.
    sig { params(id: String, outcome: String, sim_time: Time).returns(Notification) }
    def resolve_dispute(id, outcome, sim_time)
      raise Params.invalid('outcome must be won or lost', 'outcome') unless %w[won lost].include?(outcome)

      @mutex.synchronize do
        dispute = @disputes[id]
        raise RequestError.new(404, 'dispute_not_found', "no dispute #{id}") if dispute.nil?
        raise RequestError.new(409, 'dispute_already_closed', "#{id} closed #{dispute.outcome}") if dispute.outcome
        if sim_time < dispute.opened_at
          raise RequestError.new(409, 'dispute_not_open', "#{id} opens at #{dispute.opened_at.iso8601}")
        end

        dispute.outcome = outcome
        dispute.closed_at = sim_time
        # A won dispute returns the funds, which settle like anything else.
        record_movement('dispute_reversal', dispute.id, dispute, dispute.amount, sim_time) if outcome == 'won'
        @notifications.schedule('dispute.closed', id, sim_time,
                                'dispute_id' => id, 'outcome' => outcome,
                                'acquirer_reference' => dispute.acquirer_reference,
                                'amount' => dispute.amount, 'currency' => dispute.currency)
      end
    end

    SECONDS_PER_DAY = 86_400

    # Generates (or returns the frozen) settlement file for `date`. See Settlement.
    sig do
      params(date: Date, inject: T::Array[T::Hash[String, T.untyped]], sim_time: Time)
        .returns(Settlement::SettlementFile)
    end
    def settlement_file(date, inject, sim_time)
      @mutex.synchronize do
        config = @config
        @settlement.generate(date, sim_time: sim_time, inject: inject, default_seed: config.seed) do |amount, currency|
          config.fee_for(amount, currency)
        end
      end
    end

    sig { params(date: Date).returns(T.nilable(Settlement::SettlementFile)) }
    def stored_settlement_file(date)
      @mutex.synchronize { @settlement.file(date) }
    end

    sig { returns(T::Array[Settlement::Movement]) }
    def movements
      @mutex.synchronize { @settlement.movements }
    end

    # Back to a freshly started process: empty books and default config.
    sig { void }
    def reset!
      @mutex.synchronize do
        @config = Config.new
        @traffic = Traffic.new(@config)
        @operations.clear
        @authorizations.clear
        @disputes.clear
        @payouts.clear
        @notifications = Notifications.new
        @settlement = Settlement.new
      end
    end

    private

    sig { params(request: Submission).returns(T::Boolean) }
    def drop_after_commit?(request)
      request.type == 'authorize' && TOKENS[request.params['payment_method']]&.timeout == true
    end

    sig { params(existing: Operation, fingerprint: String).returns(Result) }
    def replay(existing, fingerprint)
      unless existing.fingerprint == fingerprint
        raise RequestError.new(409, 'idempotency_key_mismatch',
                               "Idempotency-Key #{existing.idempotency_key} was already used for a different " \
                               "#{existing.type} request")
      end

      Result.new(operation: existing, replayed: true)
    end

    sig { params(request: Submission).returns(Operation) }
    def do_authorize(request)
      params = request.params
      sim_time = request.sim_time
      key = request.key
      payment_method = Params.string(params, 'payment_method')
      token = TOKENS.fetch(payment_method) do
        raise Params.invalid("unknown test payment method #{payment_method}", 'payment_method')
      end
      amount = Params.positive_amount(params)
      currency = Params.currency(params)
      capture = Params.boolean(params, 'capture', default: false)
      reference = Params.optional_string(params, 'reference')

      acquirer_reference = Ids.derive('acq', key)
      auth = Authorization.new(acquirer_reference: acquirer_reference, reference: reference,
                               payment_method: payment_method, amount: amount, currency: currency,
                               approved: token.decline_code.nil?, created_at: sim_time)
      @authorizations[acquirer_reference] = auth
      record_capture(auth, amount, sim_time, Ids.derive('op', key)) if capture && auth.approved

      Operation.new(id: Ids.derive('op', key), type: 'authorize',
                    status: auth.approved ? 'approved' : 'declined', decline_code: token.decline_code,
                    acquirer_reference: acquirer_reference, reference: reference, amount: amount,
                    currency: currency, idempotency_key: key, fingerprint: request.fingerprint,
                    created_at: sim_time)
    end

    sig { params(request: Submission).returns(Operation) }
    def do_capture(request)
      amount = Params.positive_amount(request.params)
      follow_on(request, amount) do |auth|
        # One capture per authorization. A partial capture releases the rest, as
        # card networks do, so a second capture is refused rather than summed.
        next 'already_captured' if auth.captured.positive?
        next 'amount_exceeds_authorized' if amount > auth.amount

        record_capture(auth, amount, request.sim_time, Ids.derive('op', request.key))
        nil
      end
    end

    sig { params(request: Submission).returns(Operation) }
    def do_void(request)
      follow_on(request, nil) do |auth|
        next 'already_captured' if auth.captured.positive?

        auth.voided = true
        nil
      end
    end

    sig { params(request: Submission).returns(Operation) }
    def do_refund(request)
      amount = Params.positive_amount(request.params)
      follow_on(request, amount) do |auth|
        # Once a chargeback has opened, the money is in the dispute process and a
        # refund would pay the cardholder twice, so networks refuse it.
        next 'charge_disputed' if disputed_at?(auth, request.sim_time)
        next 'amount_exceeds_captured' if amount > auth.captured - auth.refunded

        auth.refunded += amount
        record_movement('refund', Ids.derive('op', request.key), auth, -amount, request.sim_time)
        nil
      end
    end

    # Shared shape of capture, void and refund: find the authorization, apply the
    # checks every follow-on shares, then the type's own rule. The block returns a
    # failure code, or nil after it has applied its change. Business-rule failures
    # are recorded as `failed` operations under the key, so a retry sees the same
    # answer, unlike malformed requests which are refused before recording.
    sig do
      params(request: Submission, amount: T.nilable(Integer),
             rule: T.proc.params(auth: Authorization).returns(T.nilable(String))).returns(Operation)
    end
    def follow_on(request, amount, &rule)
      acquirer_reference = Params.string(request.params, 'acquirer_reference')
      currency = Params.optional_currency(request.params)
      auth = @authorizations[acquirer_reference]
      failure =
        if auth.nil? then 'unknown_reference'
        elsif !auth.approved then 'authorization_declined'
        elsif auth.voided then 'authorization_voided'
        elsif currency && currency != auth.currency then 'currency_mismatch'
        else
          rule.call(auth)
        end

      Operation.new(id: Ids.derive('op', request.key), type: request.type, status: failure ? 'failed' : 'succeeded',
                    decline_code: failure, acquirer_reference: acquirer_reference, reference: auth&.reference,
                    amount: amount || auth&.amount || 0, currency: auth&.currency || currency,
                    idempotency_key: request.key, fingerprint: request.fingerprint, created_at: request.sim_time)
    end

    sig { params(request: Submission).returns(Operation) }
    def do_payout(request)
      params = request.params
      reference = Params.string(params, 'reference')
      merchant_id = Params.string(params, 'merchant_id')
      amount = Params.positive_amount(params)
      currency = Params.currency(params)
      failure = Simulator.payout_fails?(amount) ? PAYOUT_FAILURE_CODE : nil
      payout = Payout.new(acquirer_reference: Ids.derive('acqpo', request.key), reference: reference,
                          merchant_id: merchant_id, amount: amount, currency: currency, created_at: request.sim_time,
                          failure_code: failure, settles_at: request.sim_time + SECONDS_PER_DAY)
      @payouts[payout.acquirer_reference] = payout
      data = { 'reference' => reference, 'acquirer_reference' => payout.acquirer_reference }
      data['failure_code'] = failure if failure
      @notifications.schedule(failure ? 'payout.failed' : 'payout.paid', payout.acquirer_reference,
                              payout.settles_at, data)

      # Accepted for sending; whether the bank paid it arrives later as a notification.
      Operation.new(id: Ids.derive('op', request.key), type: 'payout', status: 'succeeded', decline_code: nil,
                    acquirer_reference: payout.acquirer_reference, reference: reference, amount: amount,
                    currency: currency, idempotency_key: request.key, fingerprint: request.fingerprint,
                    created_at: request.sim_time)
    end

    sig do
      params(type: String, source_id: String, subject: T.any(Authorization, Dispute), amount: Integer,
             happened_at: Time, fee: Integer).void
    end
    def record_movement(type, source_id, subject, amount, happened_at, fee: 0)
      @settlement.record(type: type, source_id: source_id, acquirer_reference: subject.acquirer_reference,
                         amount: amount, currency: subject.currency, happened_at: happened_at, fee: fee,
                         lag_days: @config.settlement_lag_days)
    end

    sig { params(auth: Authorization, at: Time).returns(T::Boolean) }
    def disputed_at?(auth, at)
      dispute_id = auth.dispute_id
      !dispute_id.nil? && @disputes.fetch(dispute_id).opened_at <= at
    end

    sig { params(auth: Authorization, amount: Integer, sim_time: Time, operation_id: String).void }
    def record_capture(auth, amount, sim_time, operation_id)
      auth.captured = amount
      auth.captured_at = sim_time
      record_movement('capture', operation_id, auth, amount, sim_time, fee: @config.fee_for(amount, auth.currency))
      schedule_dispute(auth, sim_time) if TOKENS.fetch(auth.payment_method).dispute
    end

    # The dispute is fixed at capture time for the captured amount. A refund made
    # before it opens does not shrink it: cardholders do dispute refunded charges, and
    # Clearinghouse has to cope with that case rather than have the simulator hide it.
    sig { params(auth: Authorization, captured_at: Time).void }
    def schedule_dispute(auth, captured_at)
      dispute = Dispute.new(id: Ids.derive('dsp', auth.acquirer_reference), acquirer_reference: auth.acquirer_reference,
                            amount: auth.captured, currency: auth.currency, reason: 'fraudulent',
                            opened_at: captured_at + (@config.dispute_after_days * SECONDS_PER_DAY))
      @disputes[dispute.id] = dispute
      auth.dispute_id = dispute.id
      record_movement('dispute', dispute.id, dispute, -dispute.amount, dispute.opened_at)
      @notifications.schedule('dispute.opened', dispute.id, dispute.opened_at,
                              'dispute_id' => dispute.id, 'acquirer_reference' => dispute.acquirer_reference,
                              'amount' => dispute.amount, 'currency' => dispute.currency, 'reason' => dispute.reason)
    end
  end
end
