# typed: false
# frozen_string_literal: true

require 'net/http'

RSpec.describe Clearinghouse::Webhooks::SafeHttp do
  def outcome
    Clearinghouse::Webhooks::Egress::Outcome
  end

  let(:public_ip) { '93.184.215.14' }
  let(:records) { { 'hooks.merchant.example' => [[public_ip]] } }
  let(:resolver) { FakeResolver.new(records) }
  let(:client) { described_class.new(resolver: resolver, connect_timeout: 0.5, read_timeout: 0.5, total_timeout: 2.0) }
  # Every address anything tried to open a TCP connection to.
  let(:connects) { [] }

  # Nothing in this file may reach the real network. Record the connect and refuse it.
  def refuse_all_connections
    allow(TCPSocket).to receive(:open) do |host, *_rest|
      connects << host
      raise Errno::ECONNREFUSED, host
    end
  end

  describe 'addresses a merchant URL may not reach' do
    # [what the hostname resolves to, reason]. One row per range; the address policy
    # spec covers the ranges exhaustively, these prove SafeHttp applies it after DNS.
    resolved_cases = [
      ['127.0.0.1', 'loopback'],
      ['0.0.0.0', 'this_network'],
      ['10.1.2.3', 'private'],
      ['172.20.0.1', 'private'],
      ['192.168.0.10', 'private'],
      ['169.254.169.254', 'link_local'],
      ['100.100.100.200', 'shared_address_space_cgnat'],
      ['224.0.0.251', 'multicast'],
      ['255.255.255.255', 'broadcast'],
      ['240.1.2.3', 'reserved'],
      ['::1', 'loopback'],
      ['::', 'unspecified'],
      ['fd00::1', 'unique_local'],
      ['fe80::1', 'link_local'],
      ['::ffff:127.0.0.1', 'ipv4_mapped'],
      ['::ffff:169.254.169.254', 'ipv4_mapped'],
      ['::127.0.0.1', 'ipv4_compatible'],
      ['64:ff9b::a9fe:a9fe', 'nat64_link_local'],
      ['2002:0a00:0001::1', '6to4_private']
    ]

    resolved_cases.each do |address, reason|
      it "blocks a hostname that resolves to #{address} (#{reason}) without opening a socket" do
        refuse_all_connections
        records['internal.merchant.example'] = [[address]]
        result = client.post('https://internal.merchant.example/hook', body: '{}')
        expect(result).to be_a(outcome::Blocked)
        expect(result.reason).to eq(reason)
        expect(result.detail).to start_with('internal.merchant.example: ')
        expect(connects).to be_empty
      end
    end

    # [URL naming an address directly, reason]
    literal_cases = [
      ['https://127.0.0.1/', 'loopback'],
      ['https://169.254.169.254/latest/meta-data/', 'link_local'],
      ['https://10.0.0.1/', 'private'],
      ['https://100.64.0.1/', 'shared_address_space_cgnat'],
      ['https://0.0.0.0/', 'this_network'],
      ['https://[::1]/', 'loopback'],
      ['https://[::]/', 'unspecified'],
      ['https://[fc00::1]/', 'unique_local'],
      ['https://[fe80::1]/', 'link_local'],
      ['https://[::ffff:127.0.0.1]/', 'ipv4_mapped'],
      ['https://[::ffff:a9fe:a9fe]/', 'ipv4_mapped'],
      ['https://[2002:c0a8:0101::1]/', '6to4_private'],
      ['https://2130706433/', 'ambiguous_ip_encoding'],
      ['https://0177.0.0.1/', 'ambiguous_ip_encoding'],
      ['https://0x7f.0.0.1/', 'ambiguous_ip_encoding'],
      ['https://127.1/', 'ambiguous_ip_encoding'],
      ['https://user:pw@hooks.merchant.example/', 'userinfo'],
      ['http://hooks.merchant.example/', 'scheme_not_allowed'],
      ['http://localhost/', 'scheme_not_allowed']
    ]

    literal_cases.each do |url, reason|
      it "blocks #{url} (#{reason}) without DNS or a socket" do
        refuse_all_connections
        result = client.post(url, body: '{}')
        expect(result).to be_a(outcome::Blocked)
        expect(result.reason).to eq(reason)
        expect(resolver.lookups).to be_empty
        expect(connects).to be_empty
      end
    end

    it 'blocks a hostname if any one of its addresses is internal, even if another is public' do
      refuse_all_connections
      records['mixed.merchant.example'] = [[public_ip, '10.0.0.5']]
      result = client.post('https://mixed.merchant.example/', body: '{}')
      expect(result).to have_attributes(class: outcome::Blocked, reason: 'private')
      expect(connects).to be_empty
    end

    it 'blocks localhost by name outside test mode, after resolving it' do
      refuse_all_connections
      records['localhost'] = [['127.0.0.1', '::1']]
      expect(client.post('https://localhost/', body: '{}')).to have_attributes(class: outcome::Blocked,
                                                                               reason: 'loopback')
    end
  end

  describe 'DNS failures' do
    it 'reports an unknown host as a connection failure, not a block' do
      result = client.post('https://nowhere.merchant.example/', body: '{}')
      expect(result).to be_a(outcome::ConnectionFailed)
      expect(result.message).to include('dns', 'NXDOMAIN')
    end

    it 'reports a name with no addresses as a connection failure' do
      records['empty.merchant.example'] = [[]]
      expect(client.post('https://empty.merchant.example/', body: '{}')).to be_a(outcome::ConnectionFailed)
    end
  end

  describe 'connecting to the checked address' do
    it 'opens the socket to the address it checked, never to the hostname' do
      refuse_all_connections
      result = client.post('https://hooks.merchant.example/hook', body: '{}')
      expect(connects).to eq([public_ip])
      expect(resolver.lookups['hooks.merchant.example']).to eq(1)
      expect(result).to be_a(outcome::ConnectionFailed)
    end

    it 'ignores proxies configured in the environment' do
      refuse_all_connections
      # Net::HTTP reads http_proxy even for https URLs, so set every spelling.
      names = %w[http_proxy HTTP_PROXY https_proxy HTTPS_PROXY]
      original = ENV.to_h.slice(*names)
      begin
        names.each { |name| ENV[name] = 'http://10.0.0.1:3128' }
        # The environment really does configure a proxy for a default Net::HTTP...
        expect(Net::HTTP.new('hooks.merchant.example', 443).proxy_address).to eq('10.0.0.1')
        client.post('https://hooks.merchant.example/hook', body: '{}')
      ensure
        names.each { |name| original.key?(name) ? ENV[name] = original[name] : ENV.delete(name) }
      end
      # ...and SafeHttp still connected straight to the checked address.
      expect(connects).to eq([public_ip])
    end

    it 'configures Net::HTTP defensively rather than trusting its defaults' do
      http = client.send(:connection, client.pin('https://hooks.merchant.example/hook'))
      expect(http).to have_attributes(address: 'hooks.merchant.example', port: 443, use_ssl?: true,
                                      verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true,
                                      max_retries: 0, open_timeout: 0.5, ssl_timeout: 0.5,
                                      read_timeout: 0.5, write_timeout: 0.5)
      expect(http.instance_variable_get(:@ipaddr)).to eq(public_ip)
      expect(http).not_to be_proxy
    end

    it 'times out a connect that hangs' do
      allow(TCPSocket).to receive(:open) { sleep 2 }
      quick = described_class.new(resolver: resolver, connect_timeout: 0.1, total_timeout: 5.0)
      expect(quick.post('https://hooks.merchant.example/', body: '{}'))
        .to have_attributes(class: outcome::Timeout, phase: :connect)
    end

    it 'exposes the same checks without sending, for validating a URL at registration' do
      pinned = client.pin('https://hooks.merchant.example/hook')
      expect(pinned).to be_a(described_class::Pinned)
      expect(pinned.address).to eq(IPAddr.new(public_ip))
      expect(client.pin('https://169.254.169.254/')).to be_a(outcome::Blocked)
    end
  end

  describe 'DNS rebinding' do
    # The attacker's DNS server answers with a public address first, passing any check,
    # and with 127.0.0.1 every time after.
    let(:records) { { 'rebind.attacker.example' => [[public_ip], ['127.0.0.1']] } }
    let(:internal) { LocalHttpServer.new { |socket, _| LocalHttpServer.respond(socket, 200, 'internal admin page') } }

    before do
      # A stand-in for the network. Connecting by name resolves through the same lying
      # DNS, as the OS resolver would. 127.0.0.1 reaches the internal server; nothing
      # public is reachable from a test.
      open_socket = TCPSocket.method(:open)
      internal_port = internal.port
      allow(TCPSocket).to receive(:open) do |host, *_rest|
        ip = literal_or_resolved(host)
        connects << ip.to_s
        raise Errno::ENETUNREACH, ip.to_s unless ip.loopback?

        open_socket.call('127.0.0.1', internal_port)
      end
    end

    def literal_or_resolved(host)
      IPAddr.new(host)
    rescue IPAddr::InvalidAddressError
      resolver.resolve(host).first
    end

    after { internal.stop }

    # The bug SafeHttp exists to avoid: check the name's addresses, then hand the name
    # to Net::HTTP, which resolves it again when it connects.
    def naive_post(url, body)
      uri = URI(url)
      resolver.resolve(uri.host).each do |ip|
        raise "blocked #{ip}" unless Clearinghouse::Webhooks::Egress::IpPolicy.allowed?(ip)
      end
      Net::HTTP.start(uri.host, uri.port, nil) { |http| http.post(uri.path, body) }
    end

    it 'fools a check-then-connect client into posting to the internal server' do
      response = naive_post('http://rebind.attacker.example/hook', '{}')
      expect(resolver.lookups['rebind.attacker.example']).to eq(2)
      expect(connects).to eq(['127.0.0.1'])
      expect(internal.requests.length).to eq(1)
      expect(response.body).to eq('internal admin page')
    end

    it 'does not fool SafeHttp, which resolves once and connects to the address it checked' do
      result = client.post('https://rebind.attacker.example/hook', body: '{}')
      expect(resolver.lookups['rebind.attacker.example']).to eq(1)
      expect(connects).to eq([public_ip])
      expect(internal.requests).to be_empty
      expect(result).to be_a(outcome::ConnectionFailed)
    end

    it 'blocks outright if the attacker leads with the internal answer' do
      records['rebind.attacker.example'] = [['127.0.0.1'], [public_ip]]
      expect(client.post('https://rebind.attacker.example/hook', body: '{}')).to be_a(outcome::Blocked)
      expect(connects).to be_empty
    end
  end
end
