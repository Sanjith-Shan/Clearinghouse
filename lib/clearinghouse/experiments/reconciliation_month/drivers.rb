# typed: true
# frozen_string_literal: true

require_relative '../../../../clients/ruby/lib/clearinghouse_client'

module Clearinghouse
  module Experiments
    module ReconciliationMonth
      # A merchant the experiment trades as, and the currency it sells in.
      class MerchantHandle < T::Struct
        const :merchant, Merchant
        const :secret_key, String
        const :currency, String
      end

      # How the month's traffic reaches Clearinghouse. ApiDriver is the one there is:
      # HTTP to a running API with the Ruby client library. The interface is what the
      # runner depends on, so another way in (a load generator, the Go client) is
      # another implementation.
      module Driver
        extend T::Sig
        extend T::Helpers

        interface!

        sig { abstract.returns(String) }
        def name; end

        # Creates and confirms an automatic-capture payment. The id, or nil when the
        # card was declined.
        sig do
          abstract.params(handle: MerchantHandle, amount: Integer, payment_method: String).returns(T.nilable(String))
        end
        def pay(handle, amount:, payment_method:); end

        # The refund's status: succeeded, or failed when the acquirer refused it (it
        # refuses refunds on a charge whose dispute has opened).
        sig { abstract.params(handle: MerchantHandle, payment_intent: String, amount: Integer).returns(String) }
        def refund(handle, payment_intent:, amount:); end

        sig { abstract.params(handle: MerchantHandle, dispute: String).void }
        def accept_dispute(handle, dispute:); end

        # Pays out the whole available balance. False when there is nothing to pay
        # (the balance is zero, or negative after a dispute).
        sig { abstract.params(handle: MerchantHandle).returns(T::Boolean) }
        def payout(handle); end

        # As the operator.
        sig { abstract.params(id: String, action: String, note: String).void }
        def resolve_exception(id, action:, note:); end
      end

      # Over HTTP, through the Ruby client library, like a merchant's integration.
      class ApiDriver
        extend T::Sig
        include Driver

        sig { params(api_url: String, admin_token: String).void }
        def initialize(api_url:, admin_token:)
          @api_url = api_url
          @operator = T.let(client(admin_token), ClearinghouseClient::Client)
          @clients = T.let({}, T::Hash[String, ClearinghouseClient::Client])
        end

        sig { override.returns(String) }
        def name = 'api'

        sig do
          override.params(handle: MerchantHandle, amount: Integer, payment_method: String).returns(T.nilable(String))
        end
        def pay(handle, amount:, payment_method:)
          api = for_merchant(handle)
          intent = api.payment_intents.create(amount: amount, currency: handle.currency, payment_method: payment_method)
          api.payment_intents.confirm(intent.fetch('id'))
          intent.fetch('id')
        rescue ClearinghouseClient::CardError
          nil
        end

        sig do
          override.params(handle: MerchantHandle, payment_intent: String, amount: Integer).returns(String)
        end
        def refund(handle, payment_intent:, amount:)
          for_merchant(handle).refunds.create(payment_intent: payment_intent, amount: amount).fetch('status')
        end

        sig { override.params(handle: MerchantHandle, dispute: String).void }
        def accept_dispute(handle, dispute:)
          for_merchant(handle).request(:post, "/v1/disputes/#{dispute}/close")
        end

        sig { override.params(handle: MerchantHandle).returns(T::Boolean) }
        def payout(handle)
          for_merchant(handle).payouts.create(currency: handle.currency)
          true
        rescue ClearinghouseClient::InvalidRequestError => e
          raise unless e.code == 'balance_insufficient'

          false
        end

        sig { override.params(id: String, action: String, note: String).void }
        def resolve_exception(id, action:, note:)
          @operator.request(:post, "/v1/reconciliation_exceptions/#{id}/resolve",
                            params: { 'action' => action, 'note' => note })
        end

        private

        sig { params(handle: MerchantHandle).returns(ClearinghouseClient::Client) }
        def for_merchant(handle)
          @clients[handle.secret_key] ||= client(handle.secret_key)
        end

        sig { params(key: String).returns(ClearinghouseClient::Client) }
        def client(key)
          ClearinghouseClient::Client.new(api_key: key, base_url: @api_url, max_network_retries: 2)
        end
      end
    end
  end
end
