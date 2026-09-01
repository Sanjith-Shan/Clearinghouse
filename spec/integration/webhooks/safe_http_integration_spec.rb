# typed: false
# frozen_string_literal: true

require 'openssl'

# SafeHttp against real sockets on 127.0.0.1: delivery, statuses, redirects, timeouts,
# the body cap, and TLS with the connect address pinned while SNI, the certificate
# check and the Host header all use the hostname.
RSpec.describe Clearinghouse::Webhooks::SafeHttp do
  def outcome
    Clearinghouse::Webhooks::Egress::Outcome
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  let(:resolver) { FakeResolver.new({}) }
  let(:client) do
    described_class.new(resolver: resolver, test_mode: true, connect_timeout: 1.0, read_timeout: 0.5,
                        total_timeout: 3.0)
  end
  let(:servers) { [] }

  def serve(**options, &handler)
    LocalHttpServer.new(**options, &handler).tap { |server| servers << server }
  end

  after { servers.each(&:stop) }

  describe 'plain HTTP in test mode' do
    it 'delivers the body and headers to localhost and returns the response' do
      server = serve { |socket, _| LocalHttpServer.respond(socket, 200, 'thanks') }
      signature = { 'Clearinghouse-Signature' => 't=1,v1=ab' }
      result = client.post("http://127.0.0.1:#{server.port}/hooks/in?source=ch", body: '{"id":"evt_1"}',
                                                                                 headers: signature)
      expect(result).to have_attributes(class: outcome::Delivered, status: 200, body: 'thanks')

      request = server.requests.fetch(0)
      expect(request.request_line).to eq('POST /hooks/in?source=ch HTTP/1.1')
      expect(request.body).to eq('{"id":"evt_1"}')
      expect(request.headers).to include('content-type' => 'application/json', 'clearinghouse-signature' => 't=1,v1=ab',
                                         'user-agent' => 'Clearinghouse-Webhooks/1', 'accept-encoding' => 'identity',
                                         'host' => "127.0.0.1:#{server.port}")
    end

    it 'reaches localhost by name without asking the resolver' do
      server = serve { |socket, _| LocalHttpServer.respond(socket, 204) }
      expect(client.post("http://localhost:#{server.port}/", body: '{}'))
        .to have_attributes(class: outcome::Delivered, status: 204)
      expect(resolver.lookups).to be_empty
    end

    it 'refuses localhost when test mode is off, before connecting' do
      server = serve { |socket, _| LocalHttpServer.respond(socket, 200) }
      strict = described_class.new(resolver: resolver)
      expect(strict.post("http://127.0.0.1:#{server.port}/", body: '{}')).to be_a(outcome::Blocked)
      expect(server.requests).to be_empty
    end

    it 'reports a non-2xx as rejected, with the body' do
      server = serve { |socket, _| LocalHttpServer.respond(socket, 500, 'boom') }
      expect(client.post("http://127.0.0.1:#{server.port}/", body: '{}'))
        .to have_attributes(class: outcome::Rejected, status: 500, body: 'boom')
    end

    it 'does not follow a redirect' do
      target = serve { |socket, _| LocalHttpServer.respond(socket, 200) }
      redirector = serve do |socket, _|
        LocalHttpServer.respond(socket, 302, '', 'Location' => "http://127.0.0.1:#{target.port}/")
      end
      expect(client.post("http://127.0.0.1:#{redirector.port}/", body: '{}'))
        .to have_attributes(class: outcome::Rejected, status: 302)
      expect(target.requests).to be_empty
    end

    it 'times out a server that accepts and never answers' do
      server = serve { |_socket, _| sleep 5 }
      started = monotonic
      expect(client.post("http://127.0.0.1:#{server.port}/", body: '{}'))
        .to have_attributes(class: outcome::Timeout, phase: :read)
      expect(monotonic - started).to be < 2
    end

    it 'caps the response body and stops reading an endless one' do
      server = serve do |socket, _|
        socket.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
        chunk = 'x' * 8192
        loop { socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n") }
      end
      started = monotonic
      result = client.post("http://127.0.0.1:#{server.port}/", body: '{}')
      expect(result).to have_attributes(class: outcome::Delivered, status: 200)
      expect(result.body.bytesize).to eq(described_class::DEFAULT_MAX_BODY_BYTES)
      expect(monotonic - started).to be < 2
    end

    it 'gives up on a server that drips its headers just inside the read timeout' do
      server = serve do |socket, _|
        socket.write("HTTP/1.1 200 OK\r\nX-Slow: ")
        loop do
          socket.write('a')
          sleep 0.2
        end
      end
      dripping = described_class.new(resolver: resolver, test_mode: true, read_timeout: 0.5, total_timeout: 1.0)
      started = monotonic
      expect(dripping.post("http://127.0.0.1:#{server.port}/", body: '{}'))
        .to have_attributes(class: outcome::Timeout, phase: :total)
      expect(monotonic - started).to be_between(1.0, 2.0)
    end

    it 'reports a server that hangs up without answering as a connection failure' do
      server = serve { |socket, _| socket.close }
      expect(client.post("http://127.0.0.1:#{server.port}/", body: '{}')).to be_a(outcome::ConnectionFailed)
    end

    it 'reports a server that does not speak HTTP as a connection failure' do
      server = serve { |socket, _| socket.write("SSH-2.0-OpenSSH_9.6\r\n") }
      expect(client.post("http://127.0.0.1:#{server.port}/", body: '{}')).to be_a(outcome::ConnectionFailed)
    end

    it 'reports a refused connection as a connection failure' do
      port = TCPServer.new('127.0.0.1', 0).then { |s| s.addr[1].tap { s.close } }
      result = client.post("http://127.0.0.1:#{port}/", body: '{}')
      expect(result).to be_a(outcome::ConnectionFailed)
      expect(result.message).to include('ECONNREFUSED')
    end
  end

  describe 'HTTPS with a pinned address' do
    let(:ca_key) { OpenSSL::PKey::EC.generate('prime256v1') }
    let(:ca_cert) { build_cert(subject: '/CN=Clearinghouse Test CA', key: ca_key, issuer_key: ca_key, authority: true) }
    let(:leaf_key) { OpenSSL::PKey::EC.generate('prime256v1') }
    let(:leaf_cert) do
      build_cert(subject: '/CN=hooks.merchant.test', key: leaf_key, issuer_key: ca_key, issuer: ca_cert,
                 san: 'DNS:hooks.merchant.test')
    end
    let(:trusting) { OpenSSL::X509::Store.new.tap { |store| store.add_cert(ca_cert) } }
    let(:tls_server) do
      context = OpenSSL::SSL::SSLContext.new
      context.cert = leaf_cert
      context.key = leaf_key
      serve(ssl_context: context) { |socket, _| LocalHttpServer.respond(socket, 200, 'tls ok') }
    end
    # Both names point at 127.0.0.1, which the real policy would refuse, so these
    # examples swap in an allow-all check. What they test is the TLS path, not the policy.
    let(:resolver) do
      FakeResolver.new('hooks.merchant.test' => [['127.0.0.1']], 'wrong.merchant.test' => [['127.0.0.1']])
    end

    def build_cert(subject:, key:, issuer_key:, issuer: nil, authority: false, san: nil)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = rand(1..(2**32))
      cert.subject = OpenSSL::X509::Name.parse(subject)
      cert.issuer = issuer ? issuer.subject : cert.subject
      cert.public_key = key
      cert.not_before = Time.at(0)
      cert.not_after = Time.at(4_102_444_800) # 2100-01-01
      extensions = OpenSSL::X509::ExtensionFactory.new(issuer || cert, cert)
      cert.add_extension(extensions.create_extension('basicConstraints', authority ? 'CA:TRUE' : 'CA:FALSE', true))
      cert.add_extension(extensions.create_extension('keyUsage', 'keyCertSign,cRLSign', true)) if authority
      cert.add_extension(extensions.create_extension('subjectAltName', san)) if san
      cert.sign(issuer_key, OpenSSL::Digest.new('SHA256'))
      cert
    end

    def tls_client(cert_store)
      described_class.new(resolver: resolver, cert_store: cert_store, address_check: ->(_) {},
                          connect_timeout: 1.0, read_timeout: 1.0, total_timeout: 3.0)
    end

    it 'connects to the resolved address, sends SNI and Host for the hostname, and verifies the certificate' do
      result = tls_client(trusting).post("https://hooks.merchant.test:#{tls_server.port}/hook", body: '{}')
      expect(result).to have_attributes(class: outcome::Delivered, status: 200, body: 'tls ok')
      expect(resolver.lookups).to eq('hooks.merchant.test' => 1)
      expect(tls_server.server_names).to eq(['hooks.merchant.test'])
      expect(tls_server.requests.fetch(0).headers['host']).to eq("hooks.merchant.test:#{tls_server.port}")
    end

    it 'fails when the certificate does not name the hostname, even though the address is right' do
      result = tls_client(trusting).post("https://wrong.merchant.test:#{tls_server.port}/", body: '{}')
      expect(result).to be_a(outcome::ConnectionFailed)
      expect(result.message).to include('hostname mismatch')
      expect(tls_server.requests).to be_empty
    end

    it 'fails when the certificate chains to nothing it trusts' do
      result = tls_client(OpenSSL::X509::Store.new).post("https://hooks.merchant.test:#{tls_server.port}/", body: '{}')
      expect(result).to be_a(outcome::ConnectionFailed)
      expect(result.message).to include('certificate verify failed')
    end
  end
end
