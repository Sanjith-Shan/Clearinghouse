# typed: false
# frozen_string_literal: true

require_relative 'db'

DBHelper.clean_tables('events', 'webhook_endpoints')

# Wiring for webhook specs.
module WebhookSpecHelpers
  PUBLIC_IP = '93.184.215.14'

  # A SafeHttp whose resolver knows a public name and an internal one, and that allows
  # http://127.0.0.1 so deliveries can reach a local server.
  def self.egress(read_timeout: 1.0, total_timeout: 3.0)
    resolver = FakeResolver.new('hooks.example.com' => [[PUBLIC_IP]], 'internal.example.com' => [['10.0.0.5']])
    Clearinghouse::Webhooks::SafeHttp.new(resolver: resolver, test_mode: true, connect_timeout: 1.0,
                                          read_timeout: read_timeout, total_timeout: total_timeout)
  end

  def self.url_check
    http = egress
    ->(url) { http.pin(url) }
  end

  def self.create_endpoint(db, clock:, merchant_id:, url: 'https://hooks.example.com/in', events: ['*'],
                           api_version: Clearinghouse::Versioning.latest)
    Clearinghouse::Webhooks::Endpoints.create(db, clock: clock, merchant_id: merchant_id, url: url,
                                                  enabled_events: events, api_version: api_version,
                                                  url_check: url_check)
  end

  # The PaymentIntent fixture, as the payments work will serialize it.
  def self.payment_intent(overrides = {})
    JSON.parse(File.read(File.expand_path('../fixtures/resources/payment_intent.json', __dir__))).merge(overrides)
  end
end
