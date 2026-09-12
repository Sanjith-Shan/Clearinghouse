# typed: true
# frozen_string_literal: true

require 'json'

module Clearinghouse
  module Webhooks
    # A merchant's webhook endpoint.
    class Endpoint < T::Struct
      extend T::Sig

      const :id, String
      const :merchant_id, String
      const :url, String
      const :enabled_events, T::Array[String]
      const :api_version, String
      const :description, T.nilable(String)
      const :status, String
      const :disabled_reason, T.nilable(String)
      const :secrets, SecretRotation
      const :created_at, Time
      const :updated_at, Time

      sig { returns(T::Boolean) }
      def enabled? = status == 'enabled'

      sig { params(type: String).returns(T::Boolean) }
      def subscribed?(type)
        enabled_events.include?(EventTypes::WILDCARD) || enabled_events.include?(type)
      end

      # The latest-version API shape. The secret is shown only when the endpoint is
      # created and when its secret is rolled, as with Stripe's `secret` field.
      sig { params(include_secret: T::Boolean).returns(T::Hash[String, T.untyped]) }
      def to_api(include_secret: false)
        body = {
          'id' => id,
          'object' => 'webhook_endpoint',
          'url' => url,
          'enabled_events' => enabled_events,
          'api_version' => api_version,
          'description' => description,
          'status' => status,
          'disabled_reason' => disabled_reason,
          'previous_secret_expires_at' => secrets.previous_expires_at&.to_i,
          'created' => created_at.to_i,
          'livemode' => false
        }
        body['secret'] = secrets.current if include_secret
        body
      end
    end

    # Storing and changing webhook endpoints. Every lookup is scoped to a merchant, so
    # one merchant's endpoint id is simply not found for another.
    module Endpoints
      extend T::Sig

      # Stripe's limit on endpoints per account.
      MAX_PER_MERCHANT = 16
      DISABLED_BY_MERCHANT = 'disabled_by_merchant'

      class Error < Clearinghouse::Error; end

      # The value of one parameter was unacceptable. `param` names it for the API.
      class InvalidError < Error
        extend T::Sig

        sig { returns(String) }
        attr_reader :param, :code

        sig { params(param: String, message: String, code: String).void }
        def initialize(param, message, code: 'parameter_invalid')
          super(message)
          @param = param
          @code = code
        end
      end

      class LimitError < Error; end

      # What checks a URL before it is saved: SafeHttp#pin in production.
      UrlCheck = T.type_alias do
        T.proc.params(url: String).returns(T.any(SafeHttp::Pinned, Egress::Outcome::Blocked,
                                                 Egress::Outcome::ConnectionFailed))
      end

      sig do
        params(db: Sequel::Database, clock: Clock, merchant_id: String, url: String, enabled_events: T::Array[String],
               api_version: String, url_check: UrlCheck, description: T.nilable(String)).returns(Endpoint)
      end
      def self.create(db, clock:, merchant_id:, url:, enabled_events:, api_version:, url_check:, description: nil)
        check_url!(url, url_check)
        events = normalize_events!(enabled_events)
        now = clock.now
        endpoint = Endpoint.new(
          id: Ids.generate('we'), merchant_id: merchant_id, url: url, enabled_events: events,
          api_version: api_version, description: description, status: 'enabled', disabled_reason: nil,
          secrets: SecretRotation.generate, created_at: now, updated_at: now
        )
        db.transaction do
          # Serialises creates per merchant so two concurrent requests cannot both see
          # 15 endpoints and make 17.
          lock_key = Sequel.function(:hashtext, "webhook_endpoints:#{merchant_id}")
          db.get(Sequel.function(:pg_advisory_xact_lock, lock_key))
          if live(db).where(merchant_id: merchant_id).count >= MAX_PER_MERCHANT
            raise LimitError, "An account can have at most #{MAX_PER_MERCHANT} webhook endpoints."
          end

          db[:webhook_endpoints].insert(row_for(endpoint))
        end
        endpoint
      end

      sig { params(db: Sequel::Database, merchant_id: String, id: String).returns(T.nilable(Endpoint)) }
      def self.find(db, merchant_id, id)
        row = live(db).where(merchant_id: merchant_id, id: id).first
        row ? from_row(row) : nil
      end

      # Newest first, Stripe's list order. `starting_after` is the id of the last
      # endpoint on the previous page.
      sig do
        params(db: Sequel::Database, merchant_id: String, limit: Integer, starting_after: T.nilable(String))
          .returns([T::Array[Endpoint], T::Boolean])
      end
      def self.list(db, merchant_id, limit:, starting_after: nil)
        scope = live(db).where(merchant_id: merchant_id)
        if starting_after
          cursor = scope.where(id: starting_after).select(:created_at, :id).first
          raise InvalidError.new('starting_after', "No such webhook endpoint: '#{starting_after}'") unless cursor

          scope = scope.where(Sequel.lit('(created_at, id) < (?, ?)', cursor[:created_at], cursor[:id]))
        end
        rows = scope.order(Sequel.desc(:created_at), Sequel.desc(:id)).limit(limit + 1).all
        [rows.first(limit).map { |row| from_row(row) }, rows.length > limit]
      end

      # Changes the URL, the subscribed events, the description, or whether the endpoint
      # is enabled. Re-enabling clears the disabled reason, whoever disabled it.
      sig do
        params(db: Sequel::Database, clock: Clock, endpoint: Endpoint, url_check: UrlCheck,
               url: T.nilable(String), enabled_events: T.nilable(T::Array[String]),
               description: T.nilable(String), disabled: T.nilable(T::Boolean)).returns(Endpoint)
      end
      def self.update(db, clock:, endpoint:, url_check:, url: nil, enabled_events: nil, description: nil,
                      disabled: nil)
        changes = T.let({ updated_at: clock.now }, T::Hash[Symbol, T.untyped])
        if url
          check_url!(url, url_check)
          changes[:url] = url
        end
        changes[:enabled_events] = jsonb(normalize_events!(enabled_events)) if enabled_events
        changes[:description] = description if description
        unless disabled.nil?
          changes[:status] = disabled ? 'disabled' : 'enabled'
          changes[:disabled_reason] = disabled ? DISABLED_BY_MERCHANT : nil
        end
        row = live(db).where(id: endpoint.id, merchant_id: endpoint.merchant_id).returning.update(changes).first
        raise Error, "webhook endpoint #{endpoint.id} vanished" unless row

        from_row(row)
      end

      # Soft delete. The row stays so delivery history can still name it.
      sig { params(db: Sequel::Database, clock: Clock, endpoint: Endpoint).void }
      def self.delete(db, clock:, endpoint:)
        live(db).where(id: endpoint.id, merchant_id: endpoint.merchant_id)
                .update(deleted_at: clock.now, updated_at: clock.now)
      end

      # Generates a new current secret. The old one keeps signing for `overlap` seconds
      # (0 to 24 hours) so the merchant can deploy the new one without dropping a
      # delivery. The row is locked so two concurrent rolls cannot both keep "the
      # previous secret" and silently lose one.
      sig { params(db: Sequel::Database, clock: Clock, endpoint: Endpoint, overlap: Integer).returns(Endpoint) }
      def self.roll_secret(db, clock:, endpoint:, overlap:)
        db.transaction do
          row = live(db).where(id: endpoint.id, merchant_id: endpoint.merchant_id).for_update.first
          raise Error, "webhook endpoint #{endpoint.id} vanished" unless row

          now = clock.now
          rolled = rotation_from(row).prune(now: now).rotate(new_secret: SecretRotation.generate_secret, now: now,
                                                             overlap: overlap)
          updated = live(db).where(id: endpoint.id).returning.update(
            secret: rolled.current, previous_secret: rolled.previous,
            previous_secret_expires_at: rolled.previous_expires_at, updated_at: now
          ).first
          from_row(T.must(updated))
        end
      end

      # `*` alone, or a list of known types without duplicates.
      sig { params(events: T::Array[String]).returns(T::Array[String]) }
      def self.normalize_events!(events)
        raise InvalidError.new('enabled_events', 'must list at least one event type.') if events.empty?

        if events.include?(EventTypes::WILDCARD)
          return [EventTypes::WILDCARD] if events.uniq == [EventTypes::WILDCARD]

          raise InvalidError.new('enabled_events', "'*' cannot be combined with other event types.")
        end
        unknown = events.reject { |type| Clearinghouse::Events::TYPES.include?(type) }
        unless unknown.empty?
          raise InvalidError.new('enabled_events', "Unknown event type: #{unknown.first}. " \
                                                   "Known types: #{Clearinghouse::Events::TYPES.join(', ')}.")
        end

        events.uniq
      end

      # Refuses a URL the egress policy would block, at registration rather than at
      # the first delivery. A DNS failure is accepted: a merchant may register before
      # their DNS is live, and every delivery checks again anyway.
      sig { params(url: String, url_check: UrlCheck).void }
      def self.check_url!(url, url_check)
        result = url_check.call(url)
        return unless result.is_a?(Egress::Outcome::Blocked)

        raise InvalidError.new('url', "This URL cannot receive webhooks (#{result.reason}: #{result.detail}).",
                               code: 'url_invalid')
      end

      sig { params(db: Sequel::Database).returns(Sequel::Dataset) }
      def self.live(db)
        db[:webhook_endpoints].where(deleted_at: nil)
      end

      sig { params(endpoint: Endpoint).returns(T::Hash[Symbol, T.untyped]) }
      def self.row_for(endpoint)
        {
          id: endpoint.id, merchant_id: endpoint.merchant_id, url: endpoint.url,
          enabled_events: jsonb(endpoint.enabled_events), api_version: endpoint.api_version,
          description: endpoint.description, status: endpoint.status, disabled_reason: endpoint.disabled_reason,
          secret: endpoint.secrets.current, previous_secret: endpoint.secrets.previous,
          previous_secret_expires_at: endpoint.secrets.previous_expires_at,
          created_at: endpoint.created_at, updated_at: endpoint.updated_at
        }
      end

      sig { params(value: T.untyped).returns(Sequel::SQL::Cast) }
      def self.jsonb(value)
        Sequel.cast(JSON.generate(value), :jsonb)
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(SecretRotation) }
      def self.rotation_from(row)
        SecretRotation.new(current: row[:secret], previous: row[:previous_secret],
                           previous_expires_at: row[:previous_secret_expires_at]&.utc)
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(Endpoint) }
      def self.from_row(row)
        Endpoint.new(
          id: row[:id], merchant_id: row[:merchant_id], url: row[:url],
          enabled_events: DB.from_json(row[:enabled_events]),
          api_version: row[:api_version], description: row[:description], status: row[:status],
          disabled_reason: row[:disabled_reason], secrets: rotation_from(row),
          created_at: row[:created_at].utc, updated_at: row[:updated_at].utc
        )
      end
    end
  end
end
