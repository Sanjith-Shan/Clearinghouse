# typed: strict
# frozen_string_literal: true

require 'ipaddr'
require 'net/http'
require 'openssl'
require 'timeout'

module Clearinghouse
  module Webhooks
    # The only way Clearinghouse sends an HTTP request to a URL a merchant chose.
    #
    # A webhook URL is an attack on the sender: point it at 169.254.169.254 or an
    # internal hostname and a naive sender fetches cloud credentials or probes the
    # internal network for you. This client, in the spirit of Stripe's Smokescreen:
    #
    # 1. parses the URL strictly (Egress::Target) and allows https only;
    # 2. resolves the hostname once, itself, and checks every address it gets back
    #    against Egress::IpPolicy;
    # 3. connects to the address it checked, not to the hostname, so a DNS server that
    #    answers differently the second time (DNS rebinding) never gets a second time.
    #    Net::HTTP#ipaddr= sets the connect address while the hostname still drives SNI,
    #    certificate verification and the Host header;
    # 4. never uses a proxy from the environment, never follows redirects, and bounds
    #    every phase with a timeout and the response body with a byte cap.
    class SafeHttp
      extend T::Sig

      DEFAULT_MAX_BODY_BYTES = T.let(64 * 1024, Integer)
      USER_AGENT = 'Clearinghouse-Webhooks/1'
      LOOPBACK = IPAddr.new('127.0.0.1')

      AddressCheck = T.type_alias { T.proc.params(ip: IPAddr).returns(T.nilable(Egress::IpPolicy::Denial)) }

      # A URL that passed every check, and the address that will be connected to.
      class Pinned < T::Struct
        const :target, Egress::Target
        const :address, IPAddr
      end

      # Raised by Timeout.timeout when the whole exchange overruns. A class of our own
      # so it cannot be confused with Net::HTTP's per-phase timeouts.
      class DeadlineExceeded < StandardError; end

      CONNECTION_ERRORS = T.let([
        SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError,
        Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
      ].freeze, T::Array[T.class_of(Exception)])

      # test_mode allows http:// and loopback for exactly localhost and 127.0.0.1, so the
      # test suite can deliver to a local server. address_check is only for tests that
      # need a non-localhost name to reach a local server; production uses the default.
      sig do
        params(resolver: Egress::Resolver, test_mode: T::Boolean, connect_timeout: Float, read_timeout: Float,
               total_timeout: Float, max_body_bytes: Integer, cert_store: T.nilable(OpenSSL::X509::Store),
               address_check: T.nilable(AddressCheck)).void
      end
      def initialize(resolver:, test_mode: false, connect_timeout: 2.0, read_timeout: 5.0, total_timeout: 10.0,
                     max_body_bytes: DEFAULT_MAX_BODY_BYTES, cert_store: nil, address_check: nil)
        @resolver = resolver
        @test_mode = test_mode
        @connect_timeout = connect_timeout
        @read_timeout = read_timeout
        @total_timeout = total_timeout
        @max_body_bytes = max_body_bytes
        @cert_store = cert_store
        @address_check = T.let(address_check || ->(ip) { Egress::IpPolicy.denial(ip) }, AddressCheck)
      end

      # POSTs body to url. Never raises for anything the remote end or DNS can do.
      sig { params(url: String, body: String, headers: T::Hash[String, String]).returns(Egress::Outcome) }
      def post(url, body:, headers: {})
        pinned = pin(url)
        return pinned unless pinned.is_a?(Pinned)

        deliver(pinned, body, headers)
      end

      # Parses, resolves and checks url without sending anything. The API can use it to
      # refuse an unsafe endpoint URL when the merchant registers it, but post checks
      # again at send time, since DNS can change in between.
      sig { params(url: String).returns(T.any(Pinned, Egress::Outcome::Blocked, Egress::Outcome::ConnectionFailed)) }
      def pin(url)
        target = Egress::Target.parse(url, test_mode: @test_mode)
        unless target.is_a?(Egress::Target)
          return Egress::Outcome::Blocked.new(reason: target.reason, detail: target.detail)
        end
        return Pinned.new(target: target, address: LOOPBACK) if target.test_mode_localhost

        addresses = addresses_for(target)
        return addresses unless addresses.is_a?(Array)

        # Every address must pass, not just the one we would use: a name that resolves
        # to one public and one private address is refused outright.
        addresses.each do |ip|
          denial = @address_check.call(ip)
          next if denial.nil?

          return Egress::Outcome::Blocked.new(reason: denial.reason, detail: "#{target.host}: #{denial.detail}")
        end
        Pinned.new(target: target, address: T.must(addresses.first))
      end

      private

      sig { params(target: Egress::Target).returns(T.any(T::Array[IPAddr], Egress::Outcome::ConnectionFailed)) }
      def addresses_for(target)
        literal = target.literal_ip
        return [literal] if literal

        addresses = @resolver.resolve(target.host)
        if addresses.empty?
          return Egress::Outcome::ConnectionFailed.new(message: "dns: #{target.host} has no addresses")
        end

        addresses
      rescue Egress::Resolver::ResolutionError => e
        Egress::Outcome::ConnectionFailed.new(message: "dns: #{e.message}")
      end

      sig { params(pinned: Pinned, body: String, headers: T::Hash[String, String]).returns(Egress::Outcome) }
      def deliver(pinned, body, headers)
        http = connection(pinned)
        request = Net::HTTP::Post.new(pinned.target.request_uri)
        request['Content-Type'] = 'application/json'
        request['User-Agent'] = USER_AGENT
        # No compression, so the body cap counts the bytes on the wire and a small
        # gzip bomb cannot inflate past it inside Net::HTTP.
        request['Accept-Encoding'] = 'identity'
        headers.each { |name, value| request[name] = value }
        request.body = body

        # Net::HTTP bounds each connect and each read, but a server that sends one
        # header byte just inside every read timeout would keep us forever. The
        # overall deadline is the backstop. Net::HTTP itself uses Timeout.timeout
        # for open_timeout, so this adds no new mechanism.
        ::Timeout.timeout(@total_timeout, DeadlineExceeded) { http.start { exchange(http, request) } }
      rescue Net::OpenTimeout
        Egress::Outcome::Timeout.new(phase: :connect)
      rescue Net::ReadTimeout
        Egress::Outcome::Timeout.new(phase: :read)
      rescue Net::WriteTimeout
        Egress::Outcome::Timeout.new(phase: :write)
      rescue DeadlineExceeded
        Egress::Outcome::Timeout.new(phase: :total)
      rescue *CONNECTION_ERRORS => e
        Egress::Outcome::ConnectionFailed.new(message: "#{e.class}: #{e.message}")
      end

      sig { params(pinned: Pinned).returns(Net::HTTP) }
      def connection(pinned)
        target = pinned.target
        # nil proxy: never pick up http_proxy/https_proxy from the environment, or the
        # connection would go wherever the proxy decides rather than to the checked IP.
        http = Net::HTTP.new(target.host, target.port, nil)
        http.ipaddr = pinned.address.to_s
        http.open_timeout = @connect_timeout
        http.ssl_timeout = @connect_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @read_timeout
        http.max_retries = 0
        if target.https?
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.verify_hostname = true
          http.cert_store = @cert_store if @cert_store
        end
        http
      end

      # Sends the request and reads at most max_body_bytes of the response. Leaving the
      # block by throw skips Net::HTTP's "read the rest of the body" step, and start's
      # ensure closes the socket, so an endless response costs us nothing further.
      sig { params(http: Net::HTTP, request: Net::HTTP::Post).returns(Egress::Outcome) }
      def exchange(http, request)
        status = T.let(0, Integer)
        received = +''.b
        catch(:body_cap) do
          http.request(request) do |response|
            status = response.code.to_i
            response.read_body do |chunk|
              received << chunk.byteslice(0, @max_body_bytes - received.bytesize)
              throw :body_cap if received.bytesize >= @max_body_bytes
            end
          end
        end
        text = received.force_encoding(Encoding::UTF_8).scrub
        return Egress::Outcome::Delivered.new(status: status, body: text) if status.between?(200, 299)

        Egress::Outcome::Rejected.new(status: status, body: text)
      end
    end
  end
end
