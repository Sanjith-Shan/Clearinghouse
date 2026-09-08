# typed: true
# frozen_string_literal: true

module Clearinghouse
  # Calling RiskGate, the fraud rules engine, during confirm. See
  # docs/design/risk-integration.md.
  module Risk
  end
end

require_relative 'risk/monotonic'
require_relative 'risk/assessment'
require_relative 'risk/circuit_breaker'
require_relative 'risk/http'
require_relative 'risk/client'
