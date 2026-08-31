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
    end

    TOKENS = T.let(
      {
        'pm_card_visa' => Token.new,
        'pm_card_mastercard' => Token.new,
        'pm_card_chargeDeclined' => Token.new(decline_code: 'generic_decline'),
        'pm_card_insufficientFunds' => Token.new(decline_code: 'insufficient_funds'),
        'pm_card_expired' => Token.new(decline_code: 'expired_card'),
        'pm_card_timeout' => Token.new(timeout: true)
      }.freeze,
      T::Hash[String, Token]
    )

    MUTATIONS = %w[authorize capture void refund].freeze

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
    end

    # Commits one mutating request, or replays the stored operation for its key.
    # Validation failures raise RequestError before anything is recorded, so a
    # malformed request never burns its idempotency key.
    sig { params(type: String, key: String, params: T::Hash[String, T.untyped], sim_time: Time).returns(Result) }
    def submit(type, key, params, sim_time)
      raise ArgumentError, "unknown operation type #{type}" unless MUTATIONS.include?(type)

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
          else do_refund(request)
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

    # Per client reference (a PaymentIntent id), how many authorizations exist, how
    # many were approved, and how many actually took money. `captured` above 1 is a
    # double charge, which is what experiment 1 counts.
    sig { params(authorizations: T::Array[Authorization]).returns(T::Hash[String, T::Hash[String, Integer]]) }
    def self.charges_by_reference(authorizations)
      authorizations.each_with_object({}) do |auth, out|
        row = out[auth.reference || '(none)'] ||= %w[authorizations approved captured captured_amount
                                                     refunded_amount].to_h { |k| [k, 0] }
        row['authorizations'] += 1
        row['approved'] += 1 if auth.approved
        row['captured'] += 1 if auth.captured.positive?
        row['captured_amount'] += auth.captured
        row['refunded_amount'] += auth.refunded
      end
    end

    # Back to a freshly started process: empty books and default config.
    sig { void }
    def reset!
      @mutex.synchronize do
        @config = Config.new
        @traffic = Traffic.new(@config)
        @operations.clear
        @authorizations.clear
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
      record_capture(auth, amount, sim_time) if capture && auth.approved

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

        record_capture(auth, amount, request.sim_time)
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
        next 'amount_exceeds_captured' if amount > auth.captured - auth.refunded

        auth.refunded += amount
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

    sig { params(auth: Authorization, amount: Integer, sim_time: Time).void }
    def record_capture(auth, amount, sim_time)
      auth.captured = amount
      auth.captured_at = sim_time
    end
  end
end
