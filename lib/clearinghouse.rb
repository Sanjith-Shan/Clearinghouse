# typed: strict
# frozen_string_literal: true

require 'sorbet-runtime'

# Clearinghouse is a simulated payments API with a double-entry ledger.
module Clearinghouse
  class Error < StandardError; end
end

require_relative 'clearinghouse/clock'
require_relative 'clearinghouse/currency'
require_relative 'clearinghouse/money'
require_relative 'clearinghouse/fees'
require_relative 'clearinghouse/api'
require_relative 'clearinghouse/ledger'
require_relative 'clearinghouse/webhooks/security'
require_relative 'clearinghouse/acquirer'
require_relative 'clearinghouse/explain_cli'
require_relative 'clearinghouse/idempotency'
require_relative 'clearinghouse/payments'
require_relative 'clearinghouse/risk'
require_relative 'clearinghouse/webhooks'
require_relative 'clearinghouse/balances'
require_relative 'clearinghouse/settlement'
require_relative 'clearinghouse/scheduler'
