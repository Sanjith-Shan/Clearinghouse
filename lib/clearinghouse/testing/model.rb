# typed: true
# frozen_string_literal: true

require_relative '../../clearinghouse'

module Clearinghouse
  module Testing
    # Model-based testing of Clearinghouse (experiment 4). A reference model of the
    # domain in plain Ruby, a generator of random command sequences, a shrinker, and
    # adapters that run the same sequences against a real system. See
    # docs/design/model-testing.md.
    #
    # Test tooling: nothing in the service requires this file. It lives under lib/
    # so Sorbet checks it and bin/model-test can load it outside RSpec.
    module Model
      extend T::Sig

      class UnknownSutError < Clearinghouse::Error; end

      # Systems under test by name, for bin/model-test and reproduction scripts.
      # `plant` names a deliberately planted bug (PlantedBugs), for demonstrations.
      sig { params(name: String, plant: T.nilable(String)).returns(Sut) }
      def self.build_sut(name, plant: nil)
        if plant && name == 'model'
          raise UnknownSutError,
                "the model has no planted bugs; plant #{plant} needs --sut ledger"
        end

        case name
        when 'model' then ReferenceModel.new
        else raise UnknownSutError, "unknown system under test #{name.inspect}"
        end
      end
    end
  end
end

require_relative 'model/values'
require_relative 'model/policy'
require_relative 'model/sut'
require_relative 'model/reference_model'
require_relative 'model/checks'
require_relative 'model/generator'
require_relative 'model/session'
require_relative 'model/shrinker'
require_relative 'model/runner'
require_relative 'model/script'
