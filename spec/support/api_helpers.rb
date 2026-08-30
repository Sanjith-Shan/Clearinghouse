# typed: false
# frozen_string_literal: true

require 'json'
require 'stringio'
require 'rack/test'

# Shared wiring for API specs: one app-role connection for the whole run, a test
# clock per example, and an app built the same way config.ru builds it.
module ApiSpecHelpers
  def self.db
    @db ||= Clearinghouse::DB.connect(role: :app, max_connections: 4)
  end

  def json_body
    JSON.parse(last_response.body)
  end
end

RSpec.shared_context 'with the api app' do
  include Rack::Test::Methods
  include ApiSpecHelpers

  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:log) { nil }
  let(:app_class) { Clearinghouse::Api::App }
  let(:deps) do
    Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock, log: log, admin_token: 'admin_spec_token')
  end
  let(:app) { Clearinghouse::Api::RequestLogger.new(app_class.new(deps), deps) }
end
