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
      "#{prefix}_#{Digest::SHA256.hexdigest(parts.join('|'))[0, 24]}"
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
end
