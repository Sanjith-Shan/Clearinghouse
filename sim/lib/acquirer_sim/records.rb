# typed: true
# frozen_string_literal: true

require 'digest'
require 'time'

module AcquirerSim
  # Ids are derived from the caller's idempotency key (or another stable input) by
  # hashing, not drawn from a counter or an RNG. Two reasons. The simulator stays
  # deterministic under concurrency, because an id does not depend on which request
  # won the mutex first. And a reset simulator never hands out a reference that a
  # Clearinghouse database from an earlier run already holds for a different payment.
  module Ids
    extend T::Sig

    sig { params(prefix: String, parts: T.untyped).returns(String) }
    def self.derive(prefix, *parts)
      "#{prefix}_#{Digest::SHA256.hexdigest([prefix, *parts].join('|'))[0, 24]}"
    end
  end

  # One request the simulator committed, keyed by its idempotency key. A replay of
  # the key returns this record unchanged.
  class Operation < T::Struct
    extend T::Sig

    const :id, String
    const :type, String # authorize | capture | void | refund | payout
    const :status, String # approved | declined for authorize, succeeded | failed otherwise
    const :decline_code, T.nilable(String)
    const :acquirer_reference, T.nilable(String)
    const :reference, T.nilable(String)
    const :amount, Integer
    const :currency, T.nilable(String)
    const :idempotency_key, String
    const :fingerprint, String
    const :created_at, Time

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      {
        'id' => id, 'object' => 'operation', 'type' => type, 'status' => status,
        'decline_code' => decline_code, 'acquirer_reference' => acquirer_reference,
        'reference' => reference, 'amount' => amount, 'currency' => currency,
        'idempotency_key' => idempotency_key, 'created_at' => created_at.utc.iso8601(6)
      }
    end
  end

  # The acquirer's view of one card authorization and everything done to it since.
  class Authorization < T::Struct
    extend T::Sig

    const :acquirer_reference, String
    const :reference, T.nilable(String)
    const :payment_method, String
    const :amount, Integer
    const :currency, String
    const :approved, T::Boolean
    const :created_at, Time
    prop :captured, Integer, default: 0
    prop :captured_at, T.nilable(Time)
    prop :refunded, Integer, default: 0
    prop :voided, T::Boolean, default: false
    prop :dispute_id, T.nilable(String)

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

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      {
        'acquirer_reference' => acquirer_reference, 'reference' => reference,
        'payment_method' => payment_method, 'amount' => amount, 'currency' => currency,
        'status' => approved ? 'approved' : 'declined', 'captured' => captured,
        'captured_at' => captured_at&.utc&.iso8601(6), 'refunded' => refunded, 'voided' => voided,
        'dispute_id' => dispute_id, 'created_at' => created_at.utc.iso8601(6)
      }
    end
  end

  # A chargeback. It is scheduled when a pm_card_disputeFraudulent authorization is
  # captured and opens dispute_after_days later, for the captured amount.
  class Dispute < T::Struct
    extend T::Sig

    const :id, String
    const :acquirer_reference, String
    const :amount, Integer
    const :currency, String
    const :reason, String
    const :opened_at, Time
    prop :outcome, T.nilable(String)
    prop :closed_at, T.nilable(Time)

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      {
        'id' => id, 'acquirer_reference' => acquirer_reference, 'amount' => amount, 'currency' => currency,
        'reason' => reason, 'opened_at' => opened_at.utc.iso8601(6), 'outcome' => outcome,
        'closed_at' => closed_at&.utc&.iso8601(6)
      }
    end
  end

  # A payout to a merchant's bank, paid or failed one simulated day after it is sent.
  class Payout < T::Struct
    extend T::Sig

    const :acquirer_reference, String
    const :reference, String
    const :merchant_id, String
    const :amount, Integer
    const :currency, String
    const :created_at, Time
    const :failure_code, T.nilable(String)
    const :settles_at, Time

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      {
        'acquirer_reference' => acquirer_reference, 'reference' => reference, 'merchant_id' => merchant_id,
        'amount' => amount, 'currency' => currency, 'created_at' => created_at.utc.iso8601(6),
        'outcome' => failure_code ? 'failed' : 'paid', 'failure_code' => failure_code,
        'settles_at' => settles_at.utc.iso8601(6)
      }
    end
  end

  # Something the acquirer tells Clearinghouse asynchronously, visible once a
  # request's Sim-Time reaches `due_at`. `cursor` is assigned the first time a poll
  # sees it; see Notifications.
  class Notification < T::Struct
    extend T::Sig

    const :id, String
    const :type, String
    const :due_at, Time
    const :seq, Integer
    const :data, T::Hash[String, T.untyped]
    prop :cursor, T.nilable(Integer)

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      { 'id' => id, 'type' => type, 'created_at' => due_at.utc.iso8601(6), 'cursor' => cursor&.to_s, 'data' => data }
    end
  end
end
