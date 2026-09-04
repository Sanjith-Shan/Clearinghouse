# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Webhooks
    module Egress
      # What happened to one delivery attempt. The delivery worker switches on the class:
      # Delivered is done, Rejected, Timeout and ConnectionFailed are retried with backoff,
      # and Blocked is not retried, because the URL will be just as unsafe next time.
      module Outcome
        extend T::Sig
        extend T::Helpers

        sealed!

        # A 2xx. `body` is at most SafeHttp's body cap, for the delivery log.
        class Delivered < T::Struct
          include Outcome

          const :status, Integer
          const :body, String
        end

        # Any other status, including 3xx: redirects are not followed.
        class Rejected < T::Struct
          include Outcome

          const :status, Integer
          const :body, String
        end

        # phase is :connect, :read, :write, or :total when the overall deadline hit.
        class Timeout < T::Struct
          include Outcome

          const :phase, Symbol
        end

        # DNS failure, refused or reset connection, TLS failure (including a certificate
        # that does not match the hostname), or a response that is not HTTP.
        class ConnectionFailed < T::Struct
          include Outcome

          const :message, String
        end

        # Refused before sending a byte: the URL or an address it resolved to is unsafe.
        class Blocked < T::Struct
          include Outcome

          const :reason, String
          const :detail, String
        end
      end
    end
  end
end
