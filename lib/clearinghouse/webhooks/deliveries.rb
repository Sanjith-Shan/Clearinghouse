# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Webhooks
    # Reading and nudging webhook_deliveries rows outside the worker: the manual resend,
    # and failing whatever is still pending when an endpoint is disabled or deleted.
    module Deliveries
      extend T::Sig

      # How far back a manual resend can reach, as with `stripe events resend`.
      RESEND_WINDOW = T.let(30 * Clock::SECONDS_PER_DAY, Integer)

      class Error < Clearinghouse::Error; end

      # The API shape of one delivery.
      sig { params(row: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def self.to_api(row)
        {
          'id' => row[:id],
          'object' => 'webhook_delivery',
          'event' => row[:event_id],
          'webhook_endpoint' => row[:endpoint_id],
          'status' => row[:status],
          'attempts' => row[:attempts],
          'next_attempt' => row[:status] == 'pending' ? row[:next_attempt_at].to_i : nil,
          'last_attempt' => last_attempt(row),
          'created' => row[:created_at].to_i
        }
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(T.nilable(T::Hash[String, T.untyped])) }
      def self.last_attempt(row)
        at = row[:last_attempt_at]
        return nil unless at

        { 'at' => at.to_i, 'status' => row[:last_status], 'error' => row[:last_error],
          'duration_ms' => row[:last_duration_ms] }
      end

      # Sends `event` to `endpoint` again as soon as a worker is free. Stripe's resend
      # works the same way: it does not cancel automatic retries, and it is refused for
      # a disabled endpoint.
      #
      # - A delivery still pending keeps its retry window and is simply made due now.
      # - One that succeeded or failed gets exactly one more attempt: its deadline is set
      #   to now, so a failure marks it failed again instead of starting three more days
      #   of retries nobody asked for.
      # - An event the endpoint never received (it subscribed later) gets a new row with
      #   the same single-attempt rule.
      sig do
        params(db: Sequel::Database, clock: Clock, event: T::Hash[Symbol, T.untyped], endpoint: Endpoint)
          .returns(T::Hash[Symbol, T.untyped])
      end
      def self.resend!(db, clock:, event:, endpoint:)
        now = clock.now
        raise Error, 'This webhook endpoint is disabled.' unless endpoint.enabled?
        unless endpoint.subscribed?(event[:type])
          raise Error, "This webhook endpoint is not subscribed to #{event[:type]} events."
        end
        if event[:created_at] < now - RESEND_WINDOW
          raise Error, 'Events can be resent for 30 days after they are created.'
        end

        values = { id: Ids.generate('whd'), event_id: event[:id], endpoint_id: endpoint.id,
                   event_created_at: event[:created_at], now: now }
        db.fetch(RESEND_SQL, values).first.to_h
      end

      RESEND_SQL = <<~SQL
        INSERT INTO webhook_deliveries AS d
          (id, event_id, endpoint_id, event_created_at, created_at, next_attempt_at, retry_deadline_at)
        VALUES (:id, :event_id, :endpoint_id, :event_created_at, :now, :now, :now)
        ON CONFLICT (event_id, endpoint_id) DO UPDATE SET
          next_attempt_at = :now,
          retry_deadline_at = CASE WHEN d.status = 'pending' THEN d.retry_deadline_at ELSE :now END,
          status = 'pending',
          failed_at = NULL
        RETURNING d.*
      SQL

      # Fails every pending delivery of an endpoint. Called in the transaction that
      # disables or deletes it: Stripe likewise stops retrying for an endpoint that is
      # disabled or deleted. A delivery already in flight is failed too; if its request
      # succeeds, the worker records the success over this.
      sig { params(db: Sequel::Database, endpoint_id: String, now: Time, reason: String).returns(Integer) }
      def self.fail_pending!(db, endpoint_id:, now:, reason:)
        db[:webhook_deliveries].where(endpoint_id: endpoint_id, status: 'pending')
                               .update(status: 'failed', failed_at: now, last_error: reason,
                                       lease_token: nil, lease_expires_at: nil)
      end

      sig { params(db: Sequel::Database, event_id: String, endpoint_id: String).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def self.find(db, event_id:, endpoint_id:)
        db[:webhook_deliveries].where(event_id: event_id, endpoint_id: endpoint_id).first
      end
    end
  end
end
