# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::Egress::Target do
  # [url, test_mode, refusal reason, or nil when the URL is acceptable]
  cases = [
    ['https://hooks.merchant.example/webhooks', false, nil],
    ['https://hooks.merchant.example:8443/a/b?c=d', false, nil],
    ['HTTPS://Hooks.Merchant.Example/x', false, nil],
    ['https://93.184.215.14/hook', false, nil],
    ['https://[2606:4700:4700::1111]/hook', false, nil],
    ['https://under_score.merchant.example/', false, nil],

    # Scheme.
    ['http://hooks.merchant.example/', false, 'scheme_not_allowed'],
    ['http://hooks.merchant.example/', true, 'scheme_not_allowed'],
    ['http://localhost:4567/', false, 'scheme_not_allowed'],
    ['http://127.0.0.1:4567/', false, 'scheme_not_allowed'],
    ['http://localhost:4567/', true, nil],
    ['http://127.0.0.1:4567/', true, nil],
    ['http://127.0.0.2:4567/', true, 'scheme_not_allowed'],
    ['http://[::1]:4567/', true, 'scheme_not_allowed'],
    ['ftp://hooks.merchant.example/', false, 'scheme_not_allowed'],
    ['file:///etc/passwd', false, 'scheme_not_allowed'],
    ['gopher://127.0.0.1:6379/_FLUSHALL', false, 'scheme_not_allowed'],
    ['//hooks.merchant.example/', false, 'scheme_not_allowed'],

    # Userinfo, including the classic "which host is it" confusion.
    ['https://user:pass@hooks.merchant.example/', false, 'userinfo'],
    ['https://user@hooks.merchant.example/', false, 'userinfo'],
    ['https://hooks.merchant.example@127.0.0.1/', false, 'userinfo'],
    ['https://127.0.0.1:443@hooks.merchant.example/', false, 'userinfo'],

    # IPv4 in anything but four canonical decimal octets.
    ['https://2130706433/', false, 'ambiguous_ip_encoding'],          # decimal 127.0.0.1
    ['https://0177.0.0.1/', false, 'ambiguous_ip_encoding'],          # octal
    ['https://0x7f.0.0.1/', false, 'ambiguous_ip_encoding'],          # hex octet
    ['https://0x7f000001/', false, 'ambiguous_ip_encoding'],          # hex whole
    ['https://0X7F000001/', false, 'ambiguous_ip_encoding'],          # hex, uppercase
    ['https://017700000001/', false, 'ambiguous_ip_encoding'],        # octal whole
    ['https://127.1/', false, 'ambiguous_ip_encoding'],               # shortened
    ['https://127.0.1/', false, 'ambiguous_ip_encoding'],             # shortened
    ['https://127.0.0.01/', false, 'ambiguous_ip_encoding'],          # leading zero
    ['https://169.254.169.254.0/', false, 'ambiguous_ip_encoding'],   # five parts
    ['https://256.0.0.1/', false, 'ambiguous_ip_encoding'],           # out of range
    ['https://hooks.merchant.0x1/', false, 'ambiguous_ip_encoding'],  # numeric last label
    ['https://0/', false, 'ambiguous_ip_encoding'],

    # Hosts that are not plain LDH names.
    ['https://%31%32%37.0.0.1/', false, 'ambiguous_ip_encoding'],
    ['https://%6c%6f%63%61%6c%68%6f%73%74/', false, 'invalid_host'], # "localhost", percent-encoded
    ['https://hooks.merchant.example./', false, 'invalid_host'],
    ['https://hooks..merchant.example/', false, 'invalid_host'],
    ['https://-hooks.merchant.example/', false, 'invalid_host'],
    ["https://#{'a' * 64}.example/", false, 'invalid_host'],
    ['https://[::ffff:127.0.0.1/', false, 'invalid_url'],
    ['https://[fe80::1%25en0]/', false, 'invalid_url'],
    ['https://[v1.fe]/', false, 'invalid_host'], # RFC 3986 IPvFuture

    # Not URLs, or not ones we will parse.
    ['https://', false, 'invalid_url'],
    ['https:hooks.merchant.example', false, 'invalid_url'],
    ['https://hooks.merchant.example\\@127.0.0.1/', false, 'invalid_url'],
    ['https://hooks.merchant.example /', false, 'invalid_url'],
    ["https://hooks.merchant.example/\r\nX-Injected: 1", false, 'invalid_url'],
    ['https://höoks.merchant.example/', false, 'invalid_url'],
    ["https://hooks.merchant.example/#{'a' * 2048}", false, 'invalid_url'],
    ['https://hooks.merchant.example:0/', false, 'invalid_url'],
    ['https://hooks.merchant.example:65536/', false, 'invalid_url'],
    ['not a url', false, 'invalid_url']
  ]

  cases.each do |url, test_mode, reason|
    label = url.length > 70 ? "#{url[0, 70]}..." : url
    it "#{reason ? "refuses (#{reason})" : 'accepts'} #{label.inspect}#{' in test mode' if test_mode}" do
      result = described_class.parse(url, test_mode: test_mode)
      if reason
        expect(result).to be_a(described_class::Refusal)
        expect(result.reason).to eq(reason)
      else
        expect(result).to be_a(described_class)
      end
    end
  end

  it 'keeps the hostname for SNI and Host, and the path and query for the request line' do
    target = described_class.parse('https://Hooks.Merchant.Example:8443/a/b?c=d#frag', test_mode: false)
    expect([target.scheme, target.host, target.port, target.request_uri]).to eq(
      ['https', 'hooks.merchant.example', 8443, '/a/b?c=d']
    )
    expect(target.literal_ip).to be_nil
    expect(target).to be_https
  end

  it 'records a literal address, unbracketed for IPv6' do
    expect(described_class.parse('https://93.184.215.14/',
                                 test_mode: false).literal_ip).to eq(IPAddr.new('93.184.215.14'))
    v6 = described_class.parse('https://[2606:4700:4700::1111]/', test_mode: false)
    expect(v6.host).to eq('2606:4700:4700::1111')
    expect(v6.literal_ip).to eq(IPAddr.new('2606:4700:4700::1111'))
  end

  it 'refuses an IPv6 zone ID even if a URI parser let one through' do
    expect(described_class.send(:ipv6_literal, '[fe80::1%en0]')).to have_attributes(reason: 'invalid_host')
  end

  it 'marks only the test-mode localhost exception' do
    expect(described_class.parse('http://localhost:1/', test_mode: true).test_mode_localhost).to be(true)
    expect(described_class.parse('https://localhost:1/', test_mode: true).test_mode_localhost).to be(true)
    expect(described_class.parse('https://localhost:1/', test_mode: false).test_mode_localhost).to be(false)
  end
end
