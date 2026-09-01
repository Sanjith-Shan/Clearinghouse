# typed: strict
# frozen_string_literal: true

require 'ipaddr'
require 'socket'

module Clearinghouse
  module Webhooks
    module Egress
      # Turns a hostname into addresses. SafeHttp resolves exactly once per delivery,
      # through this interface, and connects to an address it got back, so tests can
      # inject a resolver that lies (see the DNS rebinding spec).
      module Resolver
        extend T::Sig
        extend T::Helpers

        interface!

        class ResolutionError < Clearinghouse::Error; end

        # Every address the name resolves to. Raises ResolutionError on failure.
        sig { abstract.params(hostname: String).returns(T::Array[IPAddr]) }
        def resolve(hostname); end
      end

      # The operating system's resolver (getaddrinfo), so /etc/hosts and the configured
      # DNS servers apply, with a timeout.
      class SystemResolver
        extend T::Sig
        include Resolver

        sig { params(timeout: Float).void }
        def initialize(timeout: 2.0)
          @timeout = timeout
        end

        sig { override.params(hostname: String).returns(T::Array[IPAddr]) }
        def resolve(hostname)
          infos = Addrinfo.getaddrinfo(hostname, nil, nil, :STREAM, nil, 0, timeout: @timeout)
          infos.map { |info| IPAddr.new(info.ip_address) }.uniq
        rescue SocketError, IPAddr::InvalidAddressError, IO::TimeoutError => e
          raise ResolutionError, "#{hostname}: #{e.message}"
        end
      end
    end
  end
end
