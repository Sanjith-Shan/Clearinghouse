# typed: false
# frozen_string_literal: true

require 'json'
require 'stringio'
require 'rack/test'
require_relative 'db'

DBHelper.clean_tables('merchants')

# Shared wiring for API specs: one app-role connection for the whole run, a test
# clock per example, and an app built the same way config.ru builds it.
module ApiSpecHelpers
  def self.db
    DBHelper.app
  end

  # Empties every registered table, ledger included, so API specs that post money
  # start from the same clean state as ledger specs.
  def self.reset_merchants!
    DBHelper.clean!
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

# A merchant in the database and headers that authenticate as it.
RSpec.shared_context 'with a merchant' do
  let(:merchant_api_version) { Clearinghouse::Versioning.latest }
  let(:merchant_and_key) do
    Clearinghouse::Merchants.create(ApiSpecHelpers.db, clock: clock, name: 'Rocket Rides',
                                                       api_version: merchant_api_version)
  end
  let(:merchant) { merchant_and_key.first }
  let(:secret_key) { merchant_and_key.last }
  let(:auth) { { 'HTTP_AUTHORIZATION' => "Bearer #{secret_key}" } }

  before { ApiSpecHelpers.reset_merchants! }
end
