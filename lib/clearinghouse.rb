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
