# typed: true
# frozen_string_literal: true

require 'json'

module Clearinghouse
  # The transactional outbox. Domain code calls `emit!` inside the database
  # transaction that makes the state change, so the event commits or rolls back
  # with it: an event exists if and only if the change happened. Webhook delivery
  # fans out from the `events` table; nothing here sends anything.
  module Events
    extend T::Sig

    # Every type Clearinghouse emits. A typo in a type would be an event nobody
    # subscribes to, so emit! refuses anything not listed.
    TYPES = %w[
      payment_intent.created
      payment_intent.amount_capturable_updated
      payment_intent.succeeded
      payment_intent.payment_failed
      payment_intent.canceled
      charge.refunded
      charge.refund.updated
      charge.dispute.created
      charge.dispute.closed
      payout.paid
      payout.failed
      webhook_endpoint.disabled
    ].freeze

    class UnknownTypeError < Clearinghouse::Error; end

    # Who caused an event, when it came from an API request.
    class Request < T::Struct
      const :id, T.nilable(String)
      const :idempotency_key, T.nilable(String)
    end

    # Writes one event and returns its id. `object` is the API object at the latest
    # version, as its `to_api` renders it.
    sig do
      params(db: Sequel::Database, merchant_id: String, type: String, object: T::Hash[String, T.untyped],
             clock: Clock, request: T.nilable(Request)).returns(String)
    end
    def self.emit!(db, merchant_id:, type:, object:, clock:, request: nil)
      raise UnknownTypeError, "unknown event type #{type.inspect}" unless TYPES.include?(type)

      id = Ids.generate('evt')
      db[:events].insert(id: id, merchant_id: merchant_id, type: type, object_id: object.fetch('id'),
                         data: DB.json(object), request_id: request&.id,
                         idempotency_key: request&.idempotency_key, created_at: clock.now)
      id
    end

    # The event envelope agreed with RiskGate (docs/design/interfaces.md), at the
    # latest version. `Versioning.render_event` renders it for an endpoint's version.
    sig { params(row: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def self.envelope(row)
      data = DB.from_json(row.fetch(:data))
      {
        'id' => row.fetch(:id),
        'object' => 'event',
        'type' => row.fetch(:type),
        'created' => row.fetch(:created_at).to_i,
        'api_version' => Versioning.latest,
        'data' => { 'object' => data }
      }
    end

    # Every event about one object, oldest first.
    sig { params(db: Sequel::Database, object_id: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def self.for_object(db, object_id)
      db[:events].where(object_id: object_id).order(:seq).map { |row| envelope(row) }
    end
  end
end
