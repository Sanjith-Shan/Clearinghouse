# typed: true
# frozen_string_literal: true

require 'json'

module Clearinghouse
  module Api
    # Rack middleware that gives every request an id and writes one JSON line when
    # it finishes. It sits outside the Sinatra app so the id exists before routing
    # and the line is written even for requests the app rejects.
    class RequestLogger
      extend T::Sig

      REQUEST_ID = 'clearinghouse.request_id'
      MERCHANT = 'clearinghouse.merchant_id'
      API_VERSION = 'clearinghouse.api_version'

      sig { params(app: T.untyped, deps: Dependencies).void }
      def initialize(app, deps)
        @app = app
        @deps = deps
      end

      sig { params(env: T::Hash[String, T.untyped]).returns(T.untyped) }
      def call(env)
        # Duration is a wall-clock measurement of this process, not simulated time,
        # so it reads the monotonic clock rather than the injected Clock.
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        request_id = Ids.generate('req')
        env[REQUEST_ID] = request_id
        status, headers, body = @app.call(env)
        headers['request-id'] = request_id
        write(env, status, started)
        [status, headers, body]
      end

      private

      sig { params(env: T::Hash[String, T.untyped], status: Integer, started: Numeric).void }
      def write(env, status, started)
        log = @deps.log
        return unless log

        line = {
          'time' => @deps.clock.now.iso8601(3),
          'method' => env['REQUEST_METHOD'],
          'path' => env['PATH_INFO'],
          'status' => status,
          'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2),
          'request_id' => env[REQUEST_ID],
          'merchant' => env[MERCHANT],
          'api_version' => env[API_VERSION],
          'idempotency_key' => env['HTTP_IDEMPOTENCY_KEY']
        }.compact
        log.puts(JSON.generate(line))
      end
    end
  end
end
