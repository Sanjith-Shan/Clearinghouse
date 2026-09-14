# typed: false
# frozen_string_literal: true

# A stand-in for `bin/completer --once` (pr/idempotency-recovery, not on this
# branch yet), so the crash matrix's completer mode runs in CI today. It does
# the least a completer must: find keys that are unfinished and whose lease has
# expired, and resume each with Runner#resume under a background context, the
# way docs/design/idempotency.md describes. Run as a script:
#
#   ruby spec/support/stand_in_completer.rb
#
# Required by spec_helper like every support file, it only defines the module.
# Once bin/completer lands, the crash matrix spec should use that instead.
module StandInCompleter
  def self.run_once
    deps = Clearinghouse::Api::Dependencies.from_env
    runner = Clearinghouse::Idempotency::Runner.new(db: deps.db, clock: deps.clock,
                                                    lock_timeout: deps.idempotency_lock_timeout)
    expired = deps.clock.now - runner.lock_timeout
    stale = deps.db[:idempotency_keys].exclude(recovery_point: 'finished')
                .where(Sequel[locked_at: nil] | (Sequel[:locked_at] < expired))
    stale.select_map(%i[id merchant_id render_options]).each do |id, merchant_id, options|
      resume(deps, runner, id, merchant_id, Clearinghouse::DB.from_json(options))
    end
  end

  def self.resume(deps, runner, id, merchant_id, options)
    merchant = Clearinghouse::Merchants.find(deps.db, merchant_id)
    ctx = Clearinghouse::Api::Context.background(deps, merchant, api_version: options.fetch('api_version'))
    renderer = Clearinghouse::Api::FlowRenderer.from_options(ctx, options)
    runner.resume(registry: Clearinghouse::Payments::Flows.registry, id: id, context: ctx, renderer: renderer)
    warn "completed key #{id}"
  rescue StandardError => e
    warn "key #{id}: #{e.class}: #{e.message}"
  end
end

if $PROGRAM_NAME == __FILE__
  require 'bundler/setup'
  require_relative '../../lib/clearinghouse'
  StandInCompleter.run_once
end
