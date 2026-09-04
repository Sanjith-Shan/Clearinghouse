# typed: strict
# frozen_string_literal: true

require 'securerandom'

module Clearinghouse
  module Webhooks
    # The signing secrets of one webhook endpoint: a current secret, and during a
    # rotation window the previous one with the time it stops being used.
    #
    # Modelled on Stripe's "roll secret": the merchant chooses to expire the old secret
    # immediately or keep it for up to 24 hours, and while both are live every delivery
    # is signed with both, so the merchant can deploy the new secret without dropping a
    # delivery. At most two secrets are ever live: rotating again during a window drops
    # the older previous secret at once.
    #
    # This is a pure value. Persisting it belongs to the webhook endpoints table.
    class SecretRotation < T::Struct
      extend T::Sig

      MAX_OVERLAP = T.let(24 * 60 * 60, Integer)
      PREFIX = 'whsec_'

      class InvalidRotation < Clearinghouse::Error; end

      const :current, String
      const :previous, T.nilable(String), default: nil
      const :previous_expires_at, T.nilable(Time), default: nil

      sig { params(current: String, previous: T.nilable(String), previous_expires_at: T.nilable(Time)).void }
      def initialize(current:, previous: nil, previous_expires_at: nil)
        raise InvalidRotation, 'current secret is empty' if current.empty?
        raise InvalidRotation, 'previous needs previous_expires_at' if previous.nil? != previous_expires_at.nil?
        raise InvalidRotation, 'previous secret equals current' if previous == current

        super
      end

      # 32 random bytes, so the HMAC key has 256 bits of entropy. The whole string,
      # prefix included, is the HMAC key, as with Stripe's whsec_ secrets.
      sig { returns(String) }
      def self.generate_secret
        PREFIX + SecureRandom.urlsafe_base64(32, false)
      end

      sig { returns(SecretRotation) }
      def self.generate
        new(current: generate_secret)
      end

      # The secrets to sign with at `now`, current first. The previous secret is live
      # strictly before its expiry, so at the expiry instant only the current one signs.
      sig { params(now: Time).returns(T::Array[String]) }
      def active_secrets(now:)
        old = previous
        expires_at = previous_expires_at
        return [current] if old.nil? || expires_at.nil? || now >= expires_at

        [current, old]
      end

      # Makes `new_secret` current. With a zero overlap the old secret dies now;
      # otherwise it keeps signing until now + overlap.
      sig { params(new_secret: String, now: Time, overlap: Integer).returns(SecretRotation) }
      def rotate(new_secret:, now:, overlap:)
        unless overlap.between?(0, MAX_OVERLAP)
          raise InvalidRotation, "overlap must be between 0 and #{MAX_OVERLAP} seconds, got #{overlap}"
        end
        raise InvalidRotation, 'the new secret must differ from the current one' if new_secret == current

        return SecretRotation.new(current: new_secret) if overlap.zero?

        SecretRotation.new(current: new_secret, previous: current, previous_expires_at: now + overlap)
      end

      # Drops an expired previous secret, so a stored rotation does not carry it forever.
      sig { params(now: Time).returns(SecretRotation) }
      def prune(now:)
        return self if active_secrets(now: now).length == (previous ? 2 : 1)

        SecretRotation.new(current: current)
      end
    end
  end
end
