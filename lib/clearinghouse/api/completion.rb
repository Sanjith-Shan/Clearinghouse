# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    # The API side of the completer: how to rebuild, from a key row alone, the
    # request context and renderer a flow needs, so an abandoned request finishes
    # exactly as if its own process had lived. Its events carry the original
    # request id, and its response is rendered at the version and expand[] the
    # original request asked for, ready for the client's retry to replay.
    module Completion
      extend T::Sig

      sig { params(deps: Dependencies, grace: T.nilable(Numeric)).returns(Idempotency::Completer) }
      def self.completer(deps, grace: nil)
        Idempotency::Completer.new(db: deps.db, clock: deps.clock, lock_timeout: deps.idempotency_lock_timeout,
                                   grace: grace || deps.idempotency_lock_timeout,
                                   resumer: ->(record) { resume(deps, record) })
      end

      sig { params(deps: Dependencies, record: Idempotency::Record).returns(Idempotency::Runner::Result) }
      def self.resume(deps, record)
        merchant = Merchants.find(deps.db, record.merchant_id) ||
                   raise(Clearinghouse::Error, "key #{record.id} names unknown merchant #{record.merchant_id}")
        ctx = Context.new(deps: deps, request_id: record.request_id, http_method: record.request_method,
                          path: record.request_path, idempotency_key: record.client_supplied ? record.key : nil,
                          api_version: String(record.render_options.fetch('api_version')), merchant: merchant)
        runner = Idempotency::Runner.new(db: deps.db, clock: deps.clock, lock_timeout: deps.idempotency_lock_timeout,
                                         crash_hook: deps.crash_hook)
        runner.resume(registry: Payments::Flows.registry, id: record.id, context: ctx,
                      renderer: FlowRenderer.from_options(ctx, record.render_options))
      end
    end
  end
end
