# typed: strict
# frozen_string_literal: true

require_relative 'idempotency/fingerprint'
require_relative 'idempotency/flow'
require_relative 'idempotency/registry'
require_relative 'idempotency/store'
require_relative 'idempotency/serializable'
require_relative 'idempotency/turnstile'
require_relative 'idempotency/crash_hook'
require_relative 'idempotency/runner'
require_relative 'idempotency/completer'

module Clearinghouse
  # Idempotency keys and crash recovery: atomic phases between foreign calls,
  # each one SERIALIZABLE transaction that also records how far the request got.
  # Built from Brandur Leach, "Implementing Stripe-like Idempotency Keys in
  # Postgres" (2017). See docs/design/idempotency.md for the contract and for
  # where this goes further than that design.
  module Idempotency
  end
end
