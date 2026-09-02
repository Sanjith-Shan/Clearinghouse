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

      # For authenticated routes, where a missing merchant is a bug, not a 401.
      sig { returns(Merchant) }
      def merchant!
        merchant || raise(Clearinghouse::Error, 'route needs an authenticated merchant')
      end

      sig { returns(Sequel::Database) }
      def db = deps.db

      sig { returns(Clock) }
      def clock = deps.clock
    end
  end
end
