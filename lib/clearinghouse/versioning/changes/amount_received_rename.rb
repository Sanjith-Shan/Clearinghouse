# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Versioning
    module Changes
      # A plain rename. "Captured" described the mechanism; "received" says what the
      # merchant cares about, and matches `amount_capturable` less confusingly.
      class AmountReceivedRename < VersionChange
        sig { override.returns(String) }
        def version = '2026-03-01'

        sig { override.returns(String) }
        def description
          'PaymentIntent `amount_captured` is renamed to `amount_received`. The value is unchanged: the ' \
            'amount captured so far, in minor units.'
        end

        sig { override.returns(T::Array[String]) }
        def resources = ['payment_intent']

        sig { override.params(object: Json).returns(Json) }
        def transform(object)
          VersionChange.rename_key(object, 'amount_received', 'amount_captured')
        end
      end
    end
  end
end
