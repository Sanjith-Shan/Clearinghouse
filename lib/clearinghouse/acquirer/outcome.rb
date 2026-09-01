# typed: true
# frozen_string_literal: true

require 'time'

module Clearinghouse
  module Acquirer
    # An operation as the acquirer recorded it.
    class Operation < T::Struct
      extend T::Sig

      const :id, String
      const :type, String
      const :status, String
      const :decline_code, T.nilable(String)
      const :acquirer_reference, T.nilable(String)
      const :reference, T.nilable(String)
      const :amount, Integer
      const :currency, T.nilable(String)
      const :idempotency_key, String
      const :created_at, Time

      sig { params(json: T::Hash[String, T.untyped]).returns(Operation) }
      def self.from_json(json)
        new(id: json.fetch('id'), type: json.fetch('type'), status: json.fetch('status'),
            decline_code: json['decline_code'], acquirer_reference: json['acquirer_reference'],
            reference: json['reference'], amount: Integer(json.fetch('amount')), currency: json['currency'],
            idempotency_key: json.fetch('idempotency_key'), created_at: Time.iso8601(json.fetch('created_at')))
      end

      sig { returns(T::Boolean) }
      def approved?
        %w[approved succeeded].include?(status)
      end
    end

    # The acquirer did it: an authorization approved, or a capture, void, refund or
    # payout accepted.
    class Approved < T::Struct
      const :operation, Operation
    end

    # The acquirer answered and said no. Definitely processed, definitely no money moved.
    class Declined < T::Struct
      const :code, String
      const :operation, Operation
    end

    # The request left this process and no answer came back: a read timeout, or the
    # connection dropped after the request was written. The acquirer may or may not
    # have committed it. The only safe moves are to resend under the same
    # Idempotency-Key or to ask with #lookup; treating this as a failure risks money
    # taken and never recorded, and retrying under a new key risks a double charge.
    class Unknown < T::Struct
      const :reason, String
    end

    # The acquirer definitely did not process the request: the connection was never
    # made, or it answered 503, which its contract reserves for "refused before doing
    # anything". Safe to retry later, and safe to give up.
    class Unavailable < T::Struct
      const :reason, String
    end

    # A lookup found nothing under the key: the acquirer never committed it.
    class NotFound < T::Struct
      const :idempotency_key, String
    end

    # Asynchronous news from the acquirer: dispute.opened, dispute.closed, payout.paid,
    # payout.failed. `data` is the payload documented in docs/design/interfaces.md.
    class Notification < T::Struct
      extend T::Sig

      const :id, String
      const :type, String
      const :created_at, Time
      const :cursor, String
      const :data, T::Hash[String, T.untyped]

      sig { params(json: T::Hash[String, T.untyped]).returns(Notification) }
      def self.from_json(json)
        new(id: json.fetch('id'), type: json.fetch('type'), created_at: Time.iso8601(json.fetch('created_at')),
            cursor: json.fetch('cursor'), data: json.fetch('data'))
      end
    end

    # One page of notifications. Pass next_cursor as `after` to get the next one.
    class NotificationPage < T::Struct
      const :data, T::Array[Notification]
      const :next_cursor, String
    end

    Outcome = T.type_alias { T.any(Approved, Declined, Unknown, Unavailable) }
    LookupOutcome = T.type_alias { T.any(Approved, Declined, NotFound, Unavailable) }

    # The acquirer refused the request as malformed (4xx), or reused an idempotency key
    # with a different body. That is a bug in the caller, not a state of the payment,
    # so it raises instead of hiding in an outcome.
    class ProtocolError < Clearinghouse::Error
      extend T::Sig

      sig { returns(Integer) }
      attr_reader :status

      sig { returns(T.nilable(String)) }
      attr_reader :code

      sig { params(status: Integer, code: T.nilable(String), message: String).void }
      def initialize(status, code, message)
        super("acquirer #{status} #{code}: #{message}")
        @status = status
        @code = code
      end
    end
  end
end
