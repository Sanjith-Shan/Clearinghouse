# typed: true
# frozen_string_literal: true

module ClearinghouseClient
  # Talks to the Clearinghouse API and retries safely.
  #
  # The one idea this class exists for: a mutating call gets its Idempotency-Key once,
  # before the first attempt, and every retry of that call sends the same key. A retry
  # after a timeout therefore cannot charge twice. If the first attempt landed, the
  # server replays its stored result (`Idempotent-Replayed: true`); if it is still
  # running, the server says 409 and we wait and ask again; if it never arrived, the
  # retry does the work for the first time.
  #
  #   client = ClearinghouseClient::Client.new(api_key: 'sk_test_...')
  #   response = client.request(:post, '/v1/refunds', params: { payment_intent: 'pi_...' })
  #   response.data            # => {"id" => "re_...", ...}
  #   response.request_id      # => "req_..."
  #
  # One connection per attempt: a retry after a broken connection needs a fresh one
  # anyway, and it keeps the class free of shared mutable state, so one client can be
  # used from several threads.
  class Client
    extend T::Sig

    DEFAULT_BASE_URL = 'http://127.0.0.1:4000'
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 60
    MUTATING = %w[POST DELETE].freeze
    METHODS = %w[GET POST DELETE].freeze

    # Raised while the connection opens. Nothing has been sent yet.
    CONNECT_ERRORS = [Net::OpenTimeout, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError].freeze
    # Raised once the connection is open. The request may have been processed.
    EXCHANGE_ERRORS = [Net::ReadTimeout, Net::WriteTimeout, EOFError, IOError, SystemCallError,
                       Net::HTTPBadResponse, OpenSSL::SSL::SSLError].freeze

    sig { returns(String) }
    attr_reader :base_url

    sig { returns(T.nilable(String)) }
    attr_reader :api_version

    sig do
      params(api_key: String, base_url: String, api_version: T.nilable(String), max_network_retries: Integer,
             open_timeout: Numeric, read_timeout: Numeric, sleeper: T.proc.params(seconds: Float).void,
             rng: Random).void
    end
    def initialize(api_key:, base_url: DEFAULT_BASE_URL, api_version: nil, max_network_retries: 2,
                   open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT,
                   sleeper: ->(seconds) { Kernel.sleep(seconds) }, rng: Random.new)
      raise ArgumentError, 'api_key must not be empty' if api_key.strip.empty?

      @api_key = api_key
      @base_url = base_url
      @uri = URI.parse(base_url)
      raise ArgumentError, "base_url must be http or https: #{base_url}" unless @uri.is_a?(URI::HTTP)

      @api_version = api_version
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @sleeper = sleeper
      @policy = RetryPolicy.new(max_retries: max_network_retries, rng: rng)
    end

    # Sends one logical call, retrying as the policy allows, and returns the
    # successful Response or raises the typed error for the final attempt.
    #
    # `params` go in the query string for GET and DELETE and as a JSON body for POST.
    # `idempotency_key` defaults to a fresh UUID for POST and DELETE; pass your own to
    # make a call safe across process restarts too (the key must then be stored with
    # the thing it creates). `api_version` overrides the client's for this call.
    sig do
      params(method: T.any(Symbol, String), path: String, params: T.nilable(T::Hash[T.untyped, T.untyped]),
             idempotency_key: T.nilable(String), api_version: T.nilable(String)).returns(Response)
    end
    def request(method, path, params: nil, idempotency_key: nil, api_version: nil)
      verb = method.to_s.upcase
      raise ArgumentError, "unsupported method #{method}" unless METHODS.include?(verb)
      raise ArgumentError, 'Idempotency-Key only applies to POST and DELETE' if idempotency_key && verb == 'GET'

      # Generated once, here, outside the retry loop. This line is the whole reason
      # retries are safe.
      key = idempotency_key || (MUTATING.include?(verb) ? SecureRandom.uuid : nil)
      headers = request_headers(key, api_version || @api_version)
      with_retries { build_and_send(verb, path, params, headers) }
    end

    private

    sig { params(block: T.proc.returns(Response)).returns(Response) }
    def with_retries(&block)
      retries = 0
      loop do
        response = begin
          block.call
        rescue APIConnectionError => e
          raise e unless @policy.retry?(retries, connection_error: e)

          retries += 1
          @sleeper.call(@policy.delay(retries))
          next
        end
        return response.with_attempts(retries + 1) if response.success?
        raise Errors.from_response(response) unless @policy.retry?(retries, response: response)

        retries += 1
        @sleeper.call(@policy.delay(retries, retry_after: response.retry_after))
      end
    end

    sig { params(key: T.nilable(String), version: T.nilable(String)).returns(T::Hash[String, String]) }
    def request_headers(key, version)
      headers = {
        'Authorization' => "Bearer #{@api_key}",
        'Accept' => 'application/json',
        'User-Agent' => "clearinghouse-ruby/#{VERSION} ruby/#{RUBY_VERSION}"
      }
      headers['Idempotency-Key'] = key if key
      headers['Clearinghouse-Version'] = version if version
      headers
    end

    sig do
      params(verb: String, path: String, params: T.nilable(T::Hash[T.untyped, T.untyped]),
             headers: T::Hash[String, String]).returns(Response)
    end
    def build_and_send(verb, path, params, headers)
      full_path = @uri.path.to_s.chomp('/') + path
      request =
        if verb == 'POST'
          Net::HTTP::Post.new(full_path, headers).tap do |post|
            post['Content-Type'] = 'application/json'
            post.body = JSON.generate(params || {})
          end
        else
          query = params.nil? || params.empty? ? '' : "?#{QueryEncoder.encode(params)}"
          (verb == 'GET' ? Net::HTTP::Get : Net::HTTP::Delete).new(full_path + query, headers)
        end
      transmit(request)
    end

    # Opening the connection and exchanging the request are separate phases so a
    # failure can say whether anything was sent (APIConnectionError#maybe_processed?).
    sig { params(request: Net::HTTPGenericRequest).returns(Response) }
    def transmit(request)
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == 'https'
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @read_timeout
      # Net::HTTP quietly retries idempotent verbs (GET, DELETE) once on its own. All
      # retries go through the policy, so they are counted, backed off and logged.
      http.max_retries = 0
      begin
        http.start
      rescue *CONNECT_ERRORS => e
        raise APIConnectionError.new("Could not connect to Clearinghouse at #{@base_url}: #{e.class}: #{e.message}",
                                     maybe_processed: false)
      end
      begin
        to_response(http.request(request))
      rescue *EXCHANGE_ERRORS => e
        raise APIConnectionError.new('Connection to Clearinghouse failed after the request was sent ' \
                                     "(#{e.class}: #{e.message}). It may or may not have been processed.",
                                     maybe_processed: true)
      ensure
        http.finish if http.started?
      end
    end

    sig { params(raw: Net::HTTPResponse).returns(Response) }
    def to_response(raw)
      headers = {}
      raw.each_header { |name, value| headers[name.downcase] = value }
      Response.new(status: Integer(raw.code, 10), headers: headers, body: raw.body.to_s)
    end
  end

  # Query strings in the bracket style the API's form parser reads:
  # `limit=3`, `expand[]=payment_method`, `metadata[order]=6735`.
  module QueryEncoder
    extend T::Sig

    sig { params(params: T::Hash[T.untyped, T.untyped]).returns(String) }
    def self.encode(params)
      URI.encode_www_form(pairs(params, nil))
    end

    sig { params(value: T.untyped, prefix: T.nilable(String)).returns(T::Array[[String, String]]) }
    def self.pairs(value, prefix)
      case value
      when Hash
        value.flat_map { |k, v| pairs(v, prefix ? "#{prefix}[#{k}]" : k.to_s) }
      when Array
        value.flat_map { |v| pairs(v, "#{prefix}[]") }
      when nil
        []
      else
        [[prefix.to_s, value.to_s]]
      end
    end
    private_class_method :pairs
  end
end
