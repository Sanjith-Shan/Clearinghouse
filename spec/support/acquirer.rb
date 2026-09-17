# typed: false
# frozen_string_literal: true

require_relative '../sim/sim_helper'

# Payments specs talk to the real acquirer simulator over real HTTP: one Puma
# server on an ephemeral port for the whole run, its books reset before each
# example. Nothing about the acquirer is faked except the faults a test asks for.
module AcquirerSpec
  def self.server
    @server ||= SimServer.start
  end

  def self.simulator
    server.simulator
  end

  # The real client, plus faults on demand. `fail_next(:authorize, :drop)` sends
  # the next authorize for real and then reports Unknown, exactly what a dropped
  # connection after the acquirer committed looks like. `:unavailable` reports
  # Unavailable without sending anything, and `:unknown_unsent` reports Unknown
  # without sending (a timeout before the request got there). `calls` records
  # every call the payments code made, lookups included.
  class ScriptedClient < Clearinghouse::Acquirer::Client
    attr_reader :calls

    def initialize(**)
      super
      @faults = Hash.new { |h, k| h[k] = [] }
      @calls = []
      @mutex = Mutex.new
    end

    def fail_next(operation, fault, times: 1)
      @mutex.synchronize { times.times { @faults[operation] << fault } }
    end

    def calls_of(operation)
      @mutex.synchronize { @calls.select { |c| c.first == operation } }
    end

    %i[authorize capture void refund payout].each do |operation|
      define_method(operation) do |**args|
        record(operation, args[:idempotency_key])
        fault = @mutex.synchronize { @faults[operation].shift }
        case fault
        when :unavailable then Clearinghouse::Acquirer::Unavailable.new(reason: 'scripted: unavailable')
        when :unknown_unsent then Clearinghouse::Acquirer::Unknown.new(reason: 'scripted: lost before sending')
        when :drop
          super(**args)
          Clearinghouse::Acquirer::Unknown.new(reason: 'scripted: response lost after the acquirer committed')
        else super(**args)
        end
      end
    end

    def lookup(key)
      record(:lookup, key)
      fault = @mutex.synchronize { @faults[:lookup].shift }
      return Clearinghouse::Acquirer::Unavailable.new(reason: 'scripted: lookup unavailable') if fault == :unavailable

      super
    end

    private

    def record(operation, key)
      @mutex.synchronize { @calls << [operation, key] }
    end
  end

  # What the acquirer's own books say about one PaymentIntent.
  def acquirer_charges(reference)
    AcquirerSpec.simulator.authorizations.select { |a| a.reference == reference }
  end

  def acquirer_captures(reference)
    acquirer_charges(reference).count { |a| a.captured.positive? }
  end
end

RSpec.shared_context 'with the acquirer' do
  include AcquirerSpec

  let(:acquirer) { AcquirerSpec::ScriptedClient.new(clock: clock, base_url: AcquirerSpec.server.url, read_timeout: 5) }
  let(:deps) do
    Clearinghouse::Api::Dependencies.new(db: ApiSpecHelpers.db, clock: clock, log: log, admin_token: 'admin_spec_token',
                                         acquirer: acquirer)
  end

  before { AcquirerSpec.simulator.reset! }
end

RSpec.configure do |config|
  config.after(:suite) { AcquirerSpec.instance_variable_get(:@server)&.stop }
end
