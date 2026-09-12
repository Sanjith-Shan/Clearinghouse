# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Webhooks
    # What an endpoint can subscribe to: any of Events::TYPES by name, or `*` for every
    # type, including ones added after the endpoint was created.
    module EventTypes
      WILDCARD = '*'
    end
  end
end
