# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    # What one request knows about itself. Built in the app's `before` filter and
    # handed to domain code, so services take a Context rather than reaching into
    # Rack or Sinatra. `merchant` and `api_version` are filled in as the request is
    # authenticated and its version resolved.
    class Context < T::Struct
      extend T::Sig

      const :deps, Dependencies
      const :request_id, String
      const :http_method, String
      const :path, String
      const :idempotency_key, T.nilable(String)
      # The version this request is rendered at: the Clearinghouse-Version header
      # if sent, else the merchant's pinned version, else the latest.
      prop :api_version, String
      # The authenticated merchant. nil only on routes that do not take a secret
      # key (/healthz, the admin bootstrap).
      prop :merchant, T.nilable(Merchant)
      # True for work done on a merchant's behalf outside a request (the expiry
      # sweep, the completer), so its events carry no request.
      const :background, T::Boolean, default: false

      # A context for a worker acting for one merchant, rendering at `api_version`.
      sig { params(deps: Dependencies, merchant: Merchant, api_version: String, request_id: String).returns(Context) }
      def self.background(deps, merchant, api_version: deps.versioning.latest, request_id: Ids.generate('req'))
        new(deps: deps, request_id: request_id, http_method: 'POST', path: '', idempotency_key: nil,
            api_version: api_version, merchant: merchant, background: true)
      end

      # For authenticated routes, where a missing merchant is a bug, not a 401.
      sig { returns(Merchant) }
      def merchant!
        merchant || raise(Clearinghouse::Error, 'route needs an authenticated merchant')
      end

      sig { returns(Acquirer::Client) }
      def acquirer!
        deps.acquirer || raise(Clearinghouse::Error, 'this app was built without an acquirer')
      end

      # For events this request causes.
      sig { returns(T.nilable(Events::Request)) }
      def event_request
        return nil if background

        Events::Request.new(id: request_id, idempotency_key: idempotency_key)
      end

      sig { returns(Sequel::Database) }
      def db = deps.db

      sig { returns(Clock) }
      def clock = deps.clock
    end
  end
end
