# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Versioning
    module Changes
      # A nested object turned into an expandable id. Before this change a
      # PaymentIntent always embedded its payment method; after it, the field is the
      # id and `expand[]=payment_method` embeds it on request.
      #
      # The latest renderer only has the id, so the transform cannot rebuild the old
      # shape from what it is given. Rather than giving transforms a database
      # handle, the change declares a forced expansion: for callers older than this
      # version the engine expands the field (through the same loader that serves
      # `expand[]`) before any transform runs. The transform is then only a guard.
      class ExpandablePaymentMethod < VersionChange
        class NotExpandedError < Clearinghouse::Error; end

        sig { override.returns(String) }
        def version = '2026-09-01'

        sig { override.returns(String) }
        def description
          'PaymentIntent `payment_method` is now the payment method id (`pm_...`) instead of the embedded ' \
            'PaymentMethod object. Pass `expand[]=payment_method` to get the object.'
        end

        sig { override.returns(T::Array[String]) }
        def resources = ['payment_intent']

        sig { override.returns(T::Array[[String, String]]) }
        def forced_expansions = [%w[payment_intent payment_method]]

        sig { override.params(object: Json).returns(Json) }
        def transform(object)
          if object['payment_method'].is_a?(String)
            raise NotExpandedError, "#{object['id']}: payment_method should have been expanded before this transform"
          end

          object
        end
      end
    end
  end
end
