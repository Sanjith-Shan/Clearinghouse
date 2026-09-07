# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # Call sites that other areas fill in. Each is one method called from exactly
    # one place, so wiring it later is a one-line change here and nowhere else.
    module Seams
      extend T::Sig

      # Called inside the capture transaction, after the capture is posted to the
      # ledger. The payouts work replaces the body with
      # `Balances::Availability.schedule!(db, flow_id:, merchant_id:, net:, available_on:)`,
      # which moves the net from pending to available when the settlement delay has
      # passed. Until then captured money stays in merchant pending.
      sig do
        params(db: Sequel::Database, flow_id: String, merchant_id: String, net: Money, available_on: Time).void
      end
      def self.schedule_availability(db, flow_id:, merchant_id:, net:, available_on:)
        _ = [db, flow_id, merchant_id, net, available_on]
      end
    end
  end
end
