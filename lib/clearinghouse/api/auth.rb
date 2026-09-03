# typed: true
# frozen_string_literal: true

require 'base64'
require 'digest'
require 'rack/utils'

module Clearinghouse
  module Api
    # Secret-key authentication. Keys arrive as `Authorization: Bearer sk_test_...`,
    # or as HTTP Basic with the key as the username and no password, which is what
    # `curl -u sk_test_...:` sends. Both are what Stripe's API accepts.
    module Auth
      extend T::Sig

      sig { params(header: T.nilable(String)).returns(T.nilable(String)) }
      def self.key_from_header(header)
        return nil if header.nil? || header.strip.empty?

        scheme, credentials = header.strip.split(/\s+/, 2)
        case scheme&.downcase
        when 'bearer' then credentials
        when 'basic' then basic_username(credentials)
        end
      end

      sig { params(credentials: T.nilable(String)).returns(T.nilable(String)) }
      def self.basic_username(credentials)
        return nil if credentials.nil?

        decoded = Base64.strict_decode64(credentials)
        decoded.split(':', 2).first
      rescue ArgumentError
        nil
      end

      sig { params(db: Sequel::Database, header: T.nilable(String)).returns(Merchant) }
      def self.merchant!(db, header)
        key = key_from_header(header)
        if key.nil? || key.empty?
          raise Errors::AuthenticationError.new(
            'You did not provide an API key. Send your secret key as "Authorization: Bearer sk_test_...".',
            code: 'api_key_missing'
          )
        end

        Merchants.authenticate(db, key) ||
          raise(Errors::AuthenticationError.new("Invalid API Key provided: #{redact(key)}", code: 'api_key_invalid'))
      end

      # Only the last four characters of a key ever appear in a response or a log.
      sig { params(key: String).returns(String) }
      def self.redact(key)
        return '****' if key.length < 12

        "#{key[0, 8]}#{'*' * 4}#{key[-4..]}"
      end

      # The admin token guards the merchant bootstrap endpoint. Both sides are
      # hashed first so the constant-time compare sees equal lengths and the
      # token's length does not leak through timing.
      sig { params(expected: T.nilable(String), header: T.nilable(String)).void }
      def self.admin!(expected, header)
        if expected.nil? || expected.empty?
          raise Errors::AuthenticationError.new(
            'Merchant creation is disabled. Set CLEARINGHOUSE_ADMIN_TOKEN to enable it.', code: 'admin_token_invalid'
          )
        end

        given = key_from_header(header).to_s
        return if Rack::Utils.secure_compare(Digest::SHA256.hexdigest(expected), Digest::SHA256.hexdigest(given))

        raise Errors::AuthenticationError.new('Merchant creation needs the admin token as a Bearer token.',
                                              code: 'admin_token_invalid')
      end
    end
  end
end
