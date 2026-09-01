# typed: true
# frozen_string_literal: true

require 'sequel'
require_relative 'ids'
require_relative 'db'
require_relative 'versioning'
require_relative 'api/errors'
require_relative 'api/params'
require_relative 'api/dependencies'
require_relative 'api/context'
require_relative 'api/request_logger'
require_relative 'api/routes/health'
require_relative 'api/app'

module Clearinghouse
  # The HTTP API: app, errors, parameters, request context and logging. See
  # docs/design/api.md for how to add an endpoint.
  module Api
    extend T::Sig

    # The Rack app config.ru runs: the request logger around the Sinatra app.
    sig { params(deps: Dependencies).returns(RequestLogger) }
    def self.rack_app(deps)
      RequestLogger.new(App.new(deps), deps)
    end
  end
end
