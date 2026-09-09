# typed: true
# frozen_string_literal: true

require_relative 'events'
require_relative 'payments/state_machine'
require_relative 'payments/payment_intent'
require_relative 'payments/payment_intents'

module Clearinghouse
  # PaymentIntents and refunds: the state machine, the services behind the API
  # endpoints, and the ledger postings they make. See docs/design/payments.md.
  module Payments
  end
end
