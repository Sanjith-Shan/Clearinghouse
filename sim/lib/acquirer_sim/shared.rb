# typed: true
# frozen_string_literal: true

# The simulator reuses Clearinghouse's pure value code (the currency exponent table,
# Money, and half-even fee rounding) and nothing else. It loads those three files
# directly instead of lib/clearinghouse.rb, because that file pulls in the database
# and the domain, and the simulator has to stay on the far side of the network.
# Reopening Clearinghouse::Error here is harmless when both are loaded in one process
# (the test suite does that); the superclass is the same.
module Clearinghouse
  class Error < StandardError; end
end

require_relative '../../../lib/clearinghouse/currency'
require_relative '../../../lib/clearinghouse/money'
require_relative '../../../lib/clearinghouse/fees'
