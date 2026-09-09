# typed: true
# frozen_string_literal: true

require_relative 'events'
require_relative 'payments/state_machine'
require_relative 'payments/payment_intent'
require_relative 'payments/payment_intents'
require_relative 'payments/errors'
require_relative 'payments/seams'
require_relative 'payments/support'
require_relative 'payments/create'
require_relative 'payments/confirm'
require_relative 'payments/capture'
require_relative 'payments/cancel'
require_relative 'payments/expiry'
require_relative 'payments/operations'

module Clearinghouse
  # PaymentIntents and refunds: the state machine, the services behind the API
  # endpoints, and the ledger postings they make. See docs/design/payments.md.
  module Payments
    extend T::Sig

    # The charge object for `expand[]=latest_charge`, scoped to the request's
    # merchant. The loader's context is the request Context.
    sig { params(ctx: T.untyped, charge_id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def self.charge_for(ctx, charge_id)
      context = T.cast(ctx, Api::Context)
      row = context.db[:payment_intents].where(merchant_id: context.merchant!.id, latest_charge: charge_id).first
      row ? PaymentIntent.from_row(row).charge_to_api : nil
    end
  end
end
