# typed: strict
# frozen_string_literal: true

module Clearinghouse
  # A merchant's money between capture and payout: when it becomes available
  # (Availability), and when it is held back for risk review (Holds). The ledger
  # holds the balances themselves; this area decides when money moves between the
  # merchant's pending, held and available accounts, and Payouts moves it out.
  # See docs/design/payouts.md.
  module Balances
  end
end

require_relative 'balances/event_sink'
require_relative 'balances/refund_requester'
require_relative 'balances/availability'
require_relative 'balances/holds'
require_relative 'payouts'
