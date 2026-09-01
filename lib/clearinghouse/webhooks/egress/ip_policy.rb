# typed: strict
# frozen_string_literal: true

require 'ipaddr'
require 'socket'

module Clearinghouse
  module Webhooks
    module Egress
      # Decides whether an address is somewhere a webhook may be delivered: publicly
      # routable unicast, nothing internal. This is the check Smokescreen makes after
      # resolving a hostname, so that webhooks cannot be used to reach, say, the cloud
      # metadata service at 169.254.169.254 or a database on 10.0.0.5.
      #
      # IPv4 is a deny list of the special-purpose ranges. IPv6 is stricter: the address
      # must be global unicast (2000::/3) or NAT64, and then the special-purpose
      # sub-ranges are denied too. Addresses that embed an IPv4 address are judged by it.
      module IpPolicy
        extend T::Sig

        # Why an address was refused: a short code and a human-readable detail.
        class Denial < T::Struct
          const :reason, String
          const :detail, String
        end

        Range = T.type_alias { [IPAddr, String] }

        sig { params(cidr: String, reason: String).returns(Range) }
        def self.range(cidr, reason)
          [IPAddr.new(cidr), reason]
        end
        private_class_method :range

        # Order matters only for the reason reported: the more specific range comes first.
        IPV4_DENIED = T.let([
          range('0.0.0.0/8', 'this_network'),
          range('10.0.0.0/8', 'private'),
          range('100.64.0.0/10', 'shared_address_space_cgnat'),
          range('127.0.0.0/8', 'loopback'),
          range('169.254.0.0/16', 'link_local'),
          range('172.16.0.0/12', 'private'),
          range('192.0.0.0/24', 'ietf_protocol_assignment'),
          range('192.0.2.0/24', 'documentation'),
          range('192.88.99.0/24', 'deprecated_6to4_relay'),
          range('192.168.0.0/16', 'private'),
          range('198.18.0.0/15', 'benchmarking'),
          range('198.51.100.0/24', 'documentation'),
          range('203.0.113.0/24', 'documentation'),
          range('224.0.0.0/4', 'multicast'),
          range('255.255.255.255/32', 'broadcast'),
          range('240.0.0.0/4', 'reserved')
        ].freeze, T::Array[Range])

        IPV6_DENIED = T.let([
          range('::/128', 'unspecified'),
          range('::1/128', 'loopback'),
          range('::ffff:0:0/96', 'ipv4_mapped'),
          range('::/96', 'ipv4_compatible'),
          range('64:ff9b:1::/48', 'nat64_local_use'),
          range('100::/64', 'discard_only'),
          range('2001::/23', 'ietf_protocol_assignment'),
          range('2001:db8::/32', 'documentation'),
          range('3fff::/20', 'documentation'),
          range('fc00::/7', 'unique_local'),
          range('fe80::/10', 'link_local'),
          range('fec0::/10', 'deprecated_site_local'),
          range('ff00::/8', 'multicast')
        ].freeze, T::Array[Range])

        GLOBAL_UNICAST = IPAddr.new('2000::/3')
        # Well-known NAT64 prefix (RFC 6052): the last 32 bits are an IPv4 address.
        NAT64 = IPAddr.new('64:ff9b::/96')
        # 6to4 (RFC 3056): bits 16..47 are an IPv4 address.
        SIX_TO_FOUR = IPAddr.new('2002::/16')

        # nil if the address may be connected to, otherwise why not.
        sig { params(address: IPAddr).returns(T.nilable(Denial)) }
        def self.denial(address)
          address.ipv4? ? denial_v4(address) : denial_v6(address)
        end

        sig { params(address: IPAddr).returns(T::Boolean) }
        def self.allowed?(address)
          denial(address).nil?
        end

        sig { params(address: IPAddr).returns(T.nilable(Denial)) }
        def self.denial_v4(address)
          hit = IPV4_DENIED.find { |net, _| net.include?(address) }
          hit && Denial.new(reason: hit[1], detail: "#{address} is in #{cidr(hit[0])}")
        end

        sig { params(address: IPAddr).returns(T.nilable(Denial)) }
        def self.denial_v6(address)
          hit = IPV6_DENIED.find { |net, _| net.include?(address) }
          if hit
            detail = "#{address} is in #{cidr(hit[0])}"
            # A mapped or compatible address is refused whatever it embeds: no public
            # AAAA record legitimately holds one. Name the embedded address in the log.
            detail += " (embeds #{embedded(address, 0)})" if %w[ipv4_mapped ipv4_compatible].include?(hit[1])
            return Denial.new(reason: hit[1], detail: detail)
          end

          # NAT64 and 6to4 route to the IPv4 address they carry, so they are exactly as
          # safe as that address.
          return embedded_denial(address, 0, 'nat64') if NAT64.include?(address)
          return embedded_denial(address, 80, '6to4') if SIX_TO_FOUR.include?(address)
          return nil if GLOBAL_UNICAST.include?(address)

          Denial.new(reason: 'not_global_unicast', detail: "#{address} is outside 2000::/3")
        end

        sig { params(address: IPAddr, shift: Integer, via: String).returns(T.nilable(Denial)) }
        def self.embedded_denial(address, shift, via)
          inner = embedded(address, shift)
          found = denial_v4(inner)
          found && Denial.new(reason: "#{via}_#{found.reason}", detail: "#{address} embeds #{found.detail}")
        end

        sig { params(address: IPAddr, shift: Integer).returns(IPAddr) }
        def self.embedded(address, shift)
          IPAddr.new((address.to_i >> shift) & 0xffff_ffff, Socket::AF_INET)
        end

        sig { params(net: IPAddr).returns(String) }
        def self.cidr(net)
          "#{net}/#{net.prefix}"
        end

        private_class_method :denial_v4, :denial_v6, :embedded_denial, :embedded, :cidr
      end
    end
  end
end
