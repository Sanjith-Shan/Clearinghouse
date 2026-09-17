# typed: true
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): talking to the API and the simulator.
  module CrashMatrix
    # What the client got for one request: a response, or a connection that ended
    # without one (the server died mid-request).
    class Reply < T::Struct
      extend T::Sig

      const :status, T.nilable(Integer)
      const :body, String, default: ''
      const :headers, T::Hash[String, String], default: {}
      # Set when no response arrived: the exception class the client saw.
      const :dropped, T.nilable(String), default: nil

      sig { returns(T::Boolean) }
      def dropped? = !dropped.nil?

      sig { returns(T::Hash[String, T.untyped]) }
      def json
        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      sig { returns(T.nilable(String)) }
      def error_code = json.dig('error', 'code')

      sig { returns(T::Boolean) }
      def replayed? = headers['idempotent-replayed'] == 'true'

      sig { returns(String) }
      def to_s
        dropped? ? "dropped (#{dropped})" : "#{status} #{error_code || json['status'] || json['object']}"
      end
    end

    # The merchant's side: form-encoded POSTs with a Bearer key and an optional
    # Idempotency-Key, over a real connection. It never retries by itself; every
    # retry is a decision the harness makes and records.
    class ApiClient
      extend T::Sig

      # Endings of a request that mean "the server went away mid-request".
      DROPPED = T.let([EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNREFUSED, Net::ReadTimeout].freeze,
                      T::Array[T.class_of(Exception)])

      sig { params(url: String, secret_key: String, read_timeout: Numeric).void }
      def initialize(url:, secret_key:, read_timeout: 60)
        @uri = T.let(URI.parse(url), URI::Generic)
        @secret_key = secret_key
        @read_timeout = read_timeout
      end

      sig { params(path: String, params: T::Hash[String, T.untyped], key: T.nilable(String)).returns(Reply) }
      def post(path, params, key: nil)
        request = Net::HTTP::Post.new(path)
        request['Authorization'] = "Bearer #{@secret_key}"
        request['Idempotency-Key'] = key if key
        request.set_form_data(params.transform_values(&:to_s))
        exchange(request)
      end

      sig { params(path: String).returns(Reply) }
      def get(path)
        request = Net::HTTP::Get.new(path)
        request['Authorization'] = "Bearer #{@secret_key}"
        exchange(request)
      end

      private

      sig { params(request: Net::HTTPRequest).returns(Reply) }
      def exchange(request)
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.open_timeout = 5
        http.read_timeout = @read_timeout
        http.max_retries = 0
        response = http.request(request)
        Reply.new(status: Integer(response.code), body: response.body.to_s,
                  headers: response.each_header.to_h { |k, v| [k.downcase, v] })
      rescue *DROPPED => e
        Reply.new(status: nil, dropped: e.class.name)
      end
    end

    # The acquirer simulator's admin surface, straight to the simulator (never
    # through the recording proxy, so the recording holds only the API's calls).
    class SimAdmin
      extend T::Sig

      sig { params(url: String).void }
      def initialize(url)
        @uri = T.let(URI.parse(url), URI::Generic)
      end

      sig { void }
      def reset!
        call(Net::HTTP::Post.new('/admin/reset'))
      end

      sig { params(config: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def configure(config)
        request = Net::HTTP::Post.new('/admin/config')
        request.body = JSON.generate(config)
        request['Content-Type'] = 'application/json'
        call(request)
      end

      # Everything the simulator committed: operations, authorizations and the
      # per-reference charge counts.
      sig { returns(T::Hash[String, T.untyped]) }
      def operations
        call(Net::HTTP::Get.new('/admin/operations'))
      end

      private

      sig { params(request: Net::HTTPRequest).returns(T::Hash[String, T.untyped]) }
      def call(request)
        response = Net::HTTP.start(T.must(@uri.host), @uri.port, open_timeout: 5, read_timeout: 30) do |http|
          http.request(request)
        end
        raise "simulator #{request.path} answered #{response.code}: #{response.body}" unless response.code == '200'

        JSON.parse(response.body.to_s)
      end
    end
  end
end
