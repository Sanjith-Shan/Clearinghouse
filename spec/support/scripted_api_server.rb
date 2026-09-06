# typed: false
# frozen_string_literal: true

require 'json'

# A fake Clearinghouse API on a real socket, for the Ruby client's specs. It answers
# attempt N with step N of a script, and repeats the last step once the script runs
# out. A step is one of:
#
#   :drop                       read the request, then close the connection unanswered
#   [:hang, seconds]            read the request, then say nothing for that long
#   [status, headers, body]     a response; a Hash body is sent as JSON
#   ->(request) { step }        decide from the request
#
# Every request is recorded, so specs can count attempts and read the headers sent.
class ScriptedApiServer
  def initialize(*script)
    @script = script
    @mutex = Mutex.new
    @count = 0
    @server = LocalHttpServer.new { |socket, request| play(socket, request) }
  end

  def self.error_body(type, code: nil, message: 'nope', **extra)
    { 'error' => { 'type' => type, 'code' => code, 'decline_code' => nil, 'param' => nil,
                   'message' => message }.merge(extra.transform_keys(&:to_s)) }
  end

  def url
    "http://127.0.0.1:#{@server.port}"
  end

  def requests
    @server.requests
  end

  def attempts
    requests.length
  end

  def idempotency_keys
    requests.map { |r| r.headers['idempotency-key'] }
  end

  def stop
    @server.stop
  end

  private

  def play(socket, request)
    step = @mutex.synchronize do
      @count += 1
      @script.fetch([@count, @script.length].min - 1)
    end
    step = step.call(request) if step.respond_to?(:call)
    case step
    in :drop then nil
    in [:hang, Numeric => seconds] then sleep(seconds)
    in [Integer => status, Hash => headers, body]
      body = JSON.generate(body) if body.is_a?(Hash)
      LocalHttpServer.respond(socket, status, body, { 'Content-Type' => 'application/json' }.merge(headers))
    end
  end
end
