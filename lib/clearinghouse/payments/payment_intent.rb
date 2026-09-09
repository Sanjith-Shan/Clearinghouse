# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # One row of payment_intents. Immutable: a change is `intent.copy(...)` saved
    # through PaymentIntents.save!, which checks lock_version.
    class PaymentIntent < T::Struct
      extend T::Sig

      const :id, String
      const :merchant_id, String
      const :amount, Integer
      const :currency, String
      const :amount_capturable, Integer, default: 0
      const :amount_received, Integer, default: 0
      const :amount_refunded, Integer, default: 0
      const :status, StateMachine::Status
      const :capture_method, String
      const :payment_method, T.nilable(String), default: nil
      const :customer_email, T.nilable(String), default: nil
      const :metadata, T::Hash[String, String], default: {}
      const :latest_charge, T.nilable(String), default: nil
      const :last_payment_error, T.nilable(T::Hash[String, T.untyped]), default: nil
      const :cancellation_reason, T.nilable(String), default: nil
      const :risk_fields, T::Hash[String, T.untyped], default: {}
      const :risk, T.nilable(T::Hash[String, T.untyped]), default: nil
      const :acquirer_reference, T.nilable(String), default: nil
      const :authorized_at, T.nilable(Time), default: nil
      const :authorization_expires_at, T.nilable(Time), default: nil
      const :attempt, Integer, default: 0
      const :lock_version, Integer, default: 0
      const :created_at, Time
      const :updated_at, Time

      CAPTURE_METHODS = %w[automatic manual].freeze

      # A copy with some fields changed. T::Struct#with round-trips through
      # serialize, which cannot deserialize an enum value it serialized.
      sig { params(changes: T.untyped).returns(PaymentIntent) }
      def copy(**changes)
        unknown = changes.keys - self.class.props.keys
        raise ArgumentError, "unknown fields #{unknown.join(', ')}" unless unknown.empty?

        T.unsafe(PaymentIntent).new(**fields, **changes)
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def fields
        self.class.props.keys.to_h { |k| [k, send(k)] }
      end

      # Value equality, which T::Struct does not define.
      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(PaymentIntent)

        fields == other.fields
      end

      sig { returns(Money) }
      def money
        Money.of(amount, currency)
      end

      # The idempotency key this intent's current confirmation attempt sends to the
      # acquirer. Derived, never random: after a crash, the code that resumes the
      # attempt must send (or look up) exactly the key the first run used. A new
      # attempt, after a decline and a new payment method, gets a new key, because it
      # is a new authorization. See docs/design/idempotency.md.
      sig { returns(String) }
      def authorization_key
        raise Clearinghouse::Error, "#{id} has not been confirmed" if attempt.zero?

        "#{id}:authorize:#{attempt}"
      end

      # The latest-version API representation, exactly the shape of
      # spec/fixtures/resources/payment_intent.json.
      sig { returns(T::Hash[String, T.untyped]) }
      def to_api
        {
          'id' => id,
          'object' => 'payment_intent',
          'amount' => amount,
          'amount_capturable' => amount_capturable,
          'amount_received' => amount_received,
          'currency' => currency,
          'status' => status.serialize,
          'capture_method' => capture_method,
          'payment_method' => payment_method,
          'customer_email' => customer_email,
          'metadata' => metadata,
          'latest_charge' => latest_charge,
          'last_payment_error' => last_payment_error,
          'created' => created_at.to_i,
          'livemode' => false,
          'cancellation_reason' => cancellation_reason,
          'risk' => risk
        }
      end

      # The charge behind `latest_charge`. Clearinghouse keeps no charges table: a
      # PaymentIntent has at most one successful authorization, and everything a
      # charge reports is already on the intent.
      sig { returns(T.nilable(T::Hash[String, T.untyped])) }
      def charge_to_api
        return nil if latest_charge.nil?

        captured = amount_received.positive?
        {
          'id' => latest_charge,
          'object' => 'charge',
          'amount' => amount,
          'amount_captured' => amount_received,
          'amount_refunded' => amount_refunded,
          'currency' => currency,
          'captured' => captured,
          'refunded' => captured && amount_refunded == amount_received,
          'payment_intent' => id,
          'payment_method' => payment_method,
          'status' => 'succeeded',
          'created' => (authorized_at || created_at).to_i,
          'livemode' => false
        }
      end

      # Sequel returns bigint and integer columns as Integer already.
      sig { params(row: T::Hash[Symbol, T.untyped]).returns(PaymentIntent) }
      def self.from_row(row)
        new(
          id: row.fetch(:id), merchant_id: row.fetch(:merchant_id), amount: row.fetch(:amount),
          currency: row.fetch(:currency), amount_capturable: row.fetch(:amount_capturable),
          amount_received: row.fetch(:amount_received), amount_refunded: row.fetch(:amount_refunded),
          status: StateMachine::Status.deserialize(row.fetch(:status)), capture_method: row.fetch(:capture_method),
          payment_method: row[:payment_method], customer_email: row[:customer_email],
          latest_charge: row[:latest_charge], cancellation_reason: row[:cancellation_reason],
          acquirer_reference: row[:acquirer_reference], metadata: object(row.fetch(:metadata)) || {},
          risk_fields: object(row.fetch(:risk_fields)) || {}, last_payment_error: object(row[:last_payment_error]),
          risk: object(row[:risk]), authorized_at: row[:authorized_at]&.utc,
          authorization_expires_at: row[:authorization_expires_at]&.utc, attempt: row.fetch(:attempt),
          lock_version: row.fetch(:lock_version), created_at: row.fetch(:created_at).utc,
          updated_at: row.fetch(:updated_at).utc
        )
      end

      sig { params(column: T.untyped).returns(T.nilable(T::Hash[String, T.untyped])) }
      def self.object(column)
        DB.from_json(column)&.to_h
      end
      private_class_method :object

      # Every column, for insert and update.
      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_row
        {
          id: id, merchant_id: merchant_id, amount: amount, currency: currency,
          amount_capturable: amount_capturable, amount_received: amount_received, amount_refunded: amount_refunded,
          status: status.serialize, capture_method: capture_method, payment_method: payment_method,
          customer_email: customer_email, metadata: DB.json(metadata), latest_charge: latest_charge,
          last_payment_error: last_payment_error.nil? ? nil : DB.json(last_payment_error),
          cancellation_reason: cancellation_reason, risk_fields: DB.json(risk_fields),
          risk: risk.nil? ? nil : DB.json(risk), acquirer_reference: acquirer_reference,
          authorized_at: authorized_at, authorization_expires_at: authorization_expires_at, attempt: attempt,
          lock_version: lock_version, created_at: created_at, updated_at: updated_at
        }
      end
    end
  end
end
