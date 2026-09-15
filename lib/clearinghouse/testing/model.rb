# typed: true
# frozen_string_literal: true

require_relative '../../clearinghouse'
require_relative '../db'

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
      # The database ones connect to CLEARINGHOUSE_DB.
      sig { params(name: String, plant: T.nilable(String)).returns(Sut) }
      def self.build_sut(name, plant: nil)
        raise UnknownSutError, "planted bugs need --sut ledger, not #{name}" if plant && name != 'ledger'

        case name
        when 'model' then ReferenceModel.new
        when 'ledger'
          T.unsafe(LedgerSut).new(db: DB.connect(role: :app, max_connections: 2),
                                  owner_db: DB.connect(role: :owner, max_connections: 1),
                                  **(plant ? PlantedBugs.ledger_sut_args(plant) : {}))
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
require_relative 'model/ledger_sut'
require_relative 'model/planted_bugs'
