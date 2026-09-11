# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # Call sites that other areas fill in. Each is one method called from exactly
    # one place, so wiring it later is a one-line change here and nowhere else.
    module Seams
      extend T::Sig

      # Called inside the capture transaction, after the capture is posted to the
      # ledger: schedules the net to move from pending to available (or to held,
      # under risk review) when the merchant's settlement delay has passed. See
      # docs/design/payouts.md.
      sig do
        params(db: Sequel::Database, flow_id: String, merchant_id: String, net: Money, available_on: Time,
               clock: Clock).void
      end
      def self.schedule_availability(db, flow_id:, merchant_id:, net:, available_on:, clock:)
        Balances::Availability.schedule!(db, flow_id: flow_id, merchant_id: merchant_id, net: net,
                                             available_on: available_on, clock: clock)
      end
    end
  end
end
