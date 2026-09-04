# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Webhooks::Egress::SystemResolver do
  let(:resolver) { described_class.new(timeout: 2.0) }

  it 'resolves through the operating system, /etc/hosts included' do
    addresses = resolver.resolve('localhost')
    expect(addresses).not_to be_empty
    expect(addresses).to all(satisfy(&:loopback?))
  end

  it 'raises ResolutionError for a name that cannot resolve' do
    # .invalid is reserved by RFC 6761 and never resolves.
    expect { resolver.resolve('no-such-host.invalid') }
      .to raise_error(Clearinghouse::Webhooks::Egress::Resolver::ResolutionError, /no-such-host\.invalid/)
  end
end
