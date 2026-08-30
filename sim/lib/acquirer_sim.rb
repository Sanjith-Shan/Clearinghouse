# typed: true
# frozen_string_literal: true

require 'sorbet-runtime'

# A simulated card acquirer that runs as its own process, so the network boundary
# between Clearinghouse and the money is real. See docs/design/sim.md.
module AcquirerSim
end

require_relative 'acquirer_sim/shared'
require_relative 'acquirer_sim/records'
require_relative 'acquirer_sim/params'
require_relative 'acquirer_sim/simulator'
require_relative 'acquirer_sim/app'
