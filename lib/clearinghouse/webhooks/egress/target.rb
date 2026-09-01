# typed: strict
# frozen_string_literal: true

require 'ipaddr'
require 'uri'

module Clearinghouse
  module Webhooks
    module Egress
      # A merchant's webhook URL, parsed strictly. Anything a URL parser, a resolver and
      # an HTTP client might each read differently is refused up front: userinfo, IPv4
      # written in decimal, octal, hex or shortened form, percent-encoded hosts, zone IDs.
      class Target < T::Struct
        extend T::Sig

        # Why a URL was refused before any DNS lookup.
        class Refusal < T::Struct
          const :reason, String
          const :detail, String
        end

        MAX_URL_LENGTH = 2048
        TEST_MODE_HOSTS = %w[localhost 127.0.0.1].freeze
        OCTET = '(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
        # Four decimal octets, no leading zeros. The only IPv4 spelling accepted.
        DOTTED_QUAD = /\A#{OCTET}(?:\.#{OCTET}){3}\z/o
        # A last label that a WHATWG URL parser or inet_aton would read as a number.
        # 127.1, 2130706433, 0x7f.0.0.1 and 0177.0.0.1 all end in one.
        NUMERIC_LABEL = /\A(?:0x[0-9a-f]*|[0-9]+)\z/
        LABEL = /\A[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?\z/

        const :scheme, String
        # The name the certificate is verified against and the Host header carries. For an
        # IP literal it is the address itself, without brackets.
        const :host, String
        const :port, Integer
        const :request_uri, String
        # Set when the URL names an address rather than a hostname.
        const :literal_ip, T.nilable(IPAddr)
        # True only for the localhost exception, which skips the address policy.
        const :test_mode_localhost, T::Boolean

        sig { returns(T::Boolean) }
        def https?
          scheme == 'https'
        end

        sig { params(url: String, test_mode: T::Boolean).returns(T.any(Target, Refusal)) }
        def self.parse(url, test_mode:)
          if url.length > MAX_URL_LENGTH || !url.ascii_only? || url.match?(/[[:space:][:cntrl:]]/)
            return refuse('invalid_url', 'too long, non-ASCII, or contains whitespace or control characters')
          end

          check_uri(URI.parse(url), test_mode)
        rescue URI::InvalidURIError => e
          refuse('invalid_url', e.message)
        end

        sig { params(uri: URI::Generic, test_mode: T::Boolean).returns(T.any(Target, Refusal)) }
        def self.check_uri(uri, test_mode)
          scheme = uri.scheme.to_s.downcase
          return refuse('scheme_not_allowed', "scheme #{scheme.inspect}") unless %w[https http].include?(scheme)
          return refuse('userinfo', 'credentials in the URL are not allowed') if uri.userinfo

          raw_host = uri.host.to_s
          return refuse('invalid_url', 'no host') if raw_host.empty?

          port = uri.port
          return refuse('invalid_url', "port #{port.inspect}") unless port.is_a?(Integer) && port.between?(1, 65_535)

          host = raw_host.start_with?('[') ? raw_host : raw_host.downcase
          localhost = test_mode && TEST_MODE_HOSTS.include?(host)
          if scheme == 'http' && !localhost
            return refuse('scheme_not_allowed',
                          'http is only allowed for localhost in test mode')
          end

          checked = host_check(host)
          return checked if checked.is_a?(Refusal)

          # Both allowed schemes parse to URI::HTTP or its subclass URI::HTTPS.
          request_uri = T.cast(uri, URI::HTTP).request_uri.to_s
          Target.new(scheme: scheme, host: checked[0], port: port, request_uri: request_uri,
                     literal_ip: checked[1], test_mode_localhost: localhost)
        end

        # Returns [host for Net::HTTP, literal address or nil], or a refusal.
        sig { params(host: String).returns(T.any([String, T.nilable(IPAddr)], Refusal)) }
        def self.host_check(host)
          return ipv6_literal(host) if host.start_with?('[')
          return [host, IPAddr.new(host)] if DOTTED_QUAD.match?(host)

          labels = host.split('.', -1)
          if NUMERIC_LABEL.match?(labels.last.to_s)
            return refuse('ambiguous_ip_encoding', "#{host} is an IPv4 address in a non-canonical form")
          end
          if host.length > 253 || labels.any? { |label| !LABEL.match?(label) }
            return refuse('invalid_host', "#{host} is not a valid hostname")
          end

          [host, nil]
        end

        sig { params(host: String).returns(T.any([String, T.nilable(IPAddr)], Refusal)) }
        def self.ipv6_literal(host)
          inner = host.delete_prefix('[').delete_suffix(']')
          # URI already refuses zone IDs, but IPAddr would accept one, so do not rely on it.
          return refuse('invalid_host', 'IPv6 zone IDs are not allowed') if inner.include?('%')

          ip = IPAddr.new(inner)
          [ip.to_s, ip]
        rescue IPAddr::InvalidAddressError
          refuse('invalid_host', "#{host} is not an IPv6 address")
        end

        sig { params(reason: String, detail: String).returns(Refusal) }
        def self.refuse(reason, detail)
          Refusal.new(reason: reason, detail: detail)
        end

        private_class_method :check_uri, :host_check, :ipv6_literal, :refuse
      end
    end
  end
end
