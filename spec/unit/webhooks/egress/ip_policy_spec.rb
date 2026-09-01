# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::Egress::IpPolicy do
  # [address, reason it is refused, or nil when it is allowed]
  cases = [
    # Public addresses are allowed.
    ['93.184.215.14', nil],
    ['8.8.8.8', nil],
    ['1.1.1.1', nil],
    ['2606:4700:4700::1111', nil],
    ['2a00:1450:4001:80b::200e', nil],

    # IPv4 special-purpose ranges.
    ['127.0.0.1', 'loopback'],
    ['127.255.255.254', 'loopback'],
    ['0.0.0.0', 'this_network'],
    ['0.1.2.3', 'this_network'],
    ['10.0.0.1', 'private'],
    ['10.255.255.255', 'private'],
    ['172.16.0.1', 'private'],
    ['172.31.255.255', 'private'],
    ['192.168.1.1', 'private'],
    ['169.254.169.254', 'link_local'],
    ['169.254.0.1', 'link_local'],
    ['100.64.0.1', 'shared_address_space_cgnat'],
    ['100.127.255.255', 'shared_address_space_cgnat'],
    ['192.0.0.8', 'ietf_protocol_assignment'],
    ['192.0.2.1', 'documentation'],
    ['198.51.100.7', 'documentation'],
    ['203.0.113.9', 'documentation'],
    ['198.18.0.1', 'benchmarking'],
    ['192.88.99.1', 'deprecated_6to4_relay'],
    ['224.0.0.1', 'multicast'],
    ['239.255.255.250', 'multicast'],
    ['240.0.0.1', 'reserved'],
    ['255.255.255.255', 'broadcast'],
    # Just outside the private ranges: allowed.
    ['172.15.255.255', nil],
    ['172.32.0.0', nil],
    ['100.63.255.255', nil],
    ['100.128.0.0', nil],
    ['11.0.0.1', nil],
    ['223.255.255.255', nil],

    # IPv6.
    ['::', 'unspecified'],
    ['::1', 'loopback'],
    ['fc00::1', 'unique_local'],
    ['fd12:3456:789a::1', 'unique_local'],
    ['fe80::1', 'link_local'],
    ['febf:ffff::1', 'link_local'],
    ['fec0::1', 'deprecated_site_local'],
    ['ff02::1', 'multicast'],
    ['2001:db8::1', 'documentation'],
    ['3fff::1', 'documentation'],
    ['2001::1', 'ietf_protocol_assignment'],
    ['100::1', 'discard_only'],
    ['4000::1', 'not_global_unicast'],

    # IPv4-mapped: refused whatever it embeds, since no public AAAA record holds one.
    ['::ffff:127.0.0.1', 'ipv4_mapped'],
    ['::ffff:169.254.169.254', 'ipv4_mapped'],
    ['::ffff:10.0.0.1', 'ipv4_mapped'],
    ['::ffff:8.8.8.8', 'ipv4_mapped'],
    # IPv4-compatible (deprecated): refused likewise.
    ['::127.0.0.1', 'ipv4_compatible'],
    ['::8.8.8.8', 'ipv4_compatible'],

    # NAT64 is as safe as the IPv4 address it carries.
    ['64:ff9b::8.8.8.8', nil],
    ['64:ff9b::127.0.0.1', 'nat64_loopback'],
    ['64:ff9b::a9fe:a9fe', 'nat64_link_local'], # 169.254.169.254
    ['64:ff9b:1::1', 'nat64_local_use'],

    # 6to4 likewise: 2002:AABB:CCDD::/48 carries AA.BB.CC.DD.
    ['2002:0808:0808::1', nil],
    ['2002:7f00:0001::1', '6to4_loopback'],
    ['2002:c0a8:0101::1', '6to4_private'],
    ['2002:a9fe:a9fe::1', '6to4_link_local']
  ]

  cases.each do |address, reason|
    it "#{reason ? 'refuses' : 'allows'} #{address}#{" (#{reason})" if reason}" do
      denial = described_class.denial(IPAddr.new(address))
      expect(denial&.reason).to eq(reason)
      expect(described_class.allowed?(IPAddr.new(address))).to eq(reason.nil?)
    end
  end

  it 'says which range matched, and what a mapped address embeds' do
    expect(described_class.denial(IPAddr.new('169.254.169.254')).detail).to eq('169.254.169.254 is in 169.254.0.0/16')
    expect(described_class.denial(IPAddr.new('::ffff:169.254.169.254')).detail).to include('embeds 169.254.169.254')
    expect(described_class.denial(IPAddr.new('2002:7f00:0001::1')).detail).to include('127.0.0.1 is in 127.0.0.0/8')
  end
end
