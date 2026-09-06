# typed: false
# frozen_string_literal: true

require_relative '../../../clients/ruby/lib/clearinghouse_client'

# An RNG whose draws are all the same number, so backoff durations are exact.
class FixedRandom < Random
  def initialize(value)
    super()
    @value = value
  end

  def rand(*)
    @value
  end
end

# Records what the client asked to sleep for instead of sleeping.
class RecordingSleeper
  attr_reader :calls

  def initialize
    @calls = []
  end

  def to_proc
    ->(seconds) { @calls << seconds }
  end
end

module ClientSpecHelpers
  UUID_V4 = /\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/

  def ok(body = { 'id' => 'pi_1', 'object' => 'payment_intent' }, headers = {})
    [200, { 'Request-Id' => 'req_ok' }.merge(headers), body]
  end

  def error(status, type, headers = {}, **fields)
    [status, { 'Request-Id' => "req_#{status}" }.merge(headers), ScriptedApiServer.error_body(type, **fields)]
  end
end

RSpec.configure do |config|
  config.include ClientSpecHelpers, file_path: %r{spec/clients/ruby}
end
