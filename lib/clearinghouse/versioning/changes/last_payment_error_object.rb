# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Versioning
    module Changes
      # One field split into two, seen from the old side: the new nested
      # `last_payment_error` object carries `decline_code`, which the old flat pair
      # had no room for. Going back, `decline_code` is dropped, because old clients
      # never received it.
      class LastPaymentErrorObject < VersionChange
        sig { override.returns(String) }
        def version = '2026-06-01'

        sig { override.returns(String) }
        def description
          'PaymentIntent `failure_code` and `failure_message` are replaced by a `last_payment_error` object with ' \
            '`code`, `decline_code` and `message`. `decline_code` is new and says why the issuer declined.'
        end

        sig { override.returns(T::Array[String]) }
        def resources = ['payment_intent']

        sig { override.params(object: Json).returns(Json) }
        def transform(object)
          return object unless object.key?('last_payment_error')

          error = object['last_payment_error']
          object.each_with_object({}) do |(key, value), old|
            if key == 'last_payment_error'
              old['failure_code'] = error&.fetch('code', nil)
              old['failure_message'] = error&.fetch('message', nil)
            else
              old[key] = value
            end
          end
        end
      end
    end
  end
end
