# typed: true
# frozen_string_literal: true

module Clearinghouse
  # Talking to the card acquirer, which in this project is the simulator in sim/.
  module Acquirer
  end
end

require_relative 'acquirer/outcome'
require_relative 'acquirer/client'
