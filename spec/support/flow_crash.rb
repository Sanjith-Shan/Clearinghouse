# typed: false
# frozen_string_literal: true

# Stands in for exit! in process: an Exception, not a StandardError, so no rescue
# in the runner sees it, exactly like a process that simply stops. (Also defined
# by spec/idempotency/crash_hook_spec.rb; reopening it is harmless.)
class SimulatedCrash < Exception; end # rubocop:disable Lint/InheritException

# Crash-matrix specs for the API's registered flows, in process: run one request
# through the real runner exactly as App#run_flow does, with the crash hook armed
# at one point, then let the completer (a "restarted process") finish it. Needs
# 'with the api app' and 'with a merchant'.
module FlowCrashHelpers
  def self.crash_points(flow_name)
    Clearinghouse::Payments::Flows.registry.crash_points.select { |p| p.flow == flow_name }
  end

  # The flow's response, or SimulatedCrash if the hook fired.
  def run_flow_directly(flow, input, path:, key:, params: {}, crash_at: nil)
    idem = Clearinghouse::Idempotency
    hook = if crash_at
             idem::CrashHook::Armed.new(crash_at.to_s, env: { 'CLEARINGHOUSE_ENV' => 'test' },
                                                       action: -> { raise SimulatedCrash })
           else
             idem::CrashHook::DISARMED
           end
    ctx = Clearinghouse::Api::Context.new(deps: deps, request_id: Clearinghouse::Ids.generate('req'),
                                          http_method: 'POST', path: path, idempotency_key: key,
                                          api_version: merchant.api_version, merchant: merchant)
    runner = idem::Runner.new(db: ApiSpecHelpers.db, clock: clock, lock_timeout: 60, crash_hook: hook)
    request = idem::Runner::Request.new(merchant_id: merchant.id, key: key, http_method: 'POST', path: path,
                                        params: params, request_id: ctx.request_id)
    renderer = Clearinghouse::Api::FlowRenderer.new(ctx, api_version: ctx.api_version, expand: [])
    runner.call(flow: flow, input: input, request: request, context: ctx, renderer: renderer).response
  end

  # What a restarted process does about a key a crash left behind: wait out the
  # lease and run the completer. Returns the completer's report, or nil when the
  # crash came before the key's first commit (there is nothing to finish).
  def complete_after_crash(key)
    row = ApiSpecHelpers.db[:idempotency_keys].where(merchant_id: merchant.id, key: key).first
    return nil unless row

    clock.advance(61)
    Clearinghouse::Api::Completion.completer(deps, grace: 60).run_once
  end
end

RSpec.configure { |c| c.include FlowCrashHelpers }
