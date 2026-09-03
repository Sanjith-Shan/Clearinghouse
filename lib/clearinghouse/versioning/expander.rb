# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Versioning
    # Knows how to turn an expandable id into its object: one loader per
    # (resource type, field). The same loaders serve a caller's `expand[]` and the
    # expansions an old API version forces.
    #
    # A loader gets the id and the render context (the request Context in the app,
    # anything in a worker) and returns the object in its latest shape. The engine
    # then versions the loaded object like any other.
    class Expander
      extend T::Sig

      class MissingObjectError < Clearinghouse::Error; end

      Loader = T.type_alias { T.proc.params(id: String, context: T.untyped).returns(T.nilable(Json)) }

      sig { void }
      def initialize
        @loaders = T.let({}, T::Hash[[String, String], Loader])
      end

      sig { params(resource: String, field: String, loader: Loader).returns(T.self_type) }
      def register(resource, field, &loader)
        @loaders[[resource, field]] = loader
        self
      end

      sig { params(resource: T.untyped, field: String).returns(T::Boolean) }
      def expandable?(resource, field)
        @loaders.key?([resource, field])
      end

      sig { params(resource: String, field: String, id: String, context: T.untyped).returns(Json) }
      def load(resource, field, id, context)
        loader = @loaders.fetch([resource, field])
        loader.call(id, context) || raise(MissingObjectError, "#{resource}.#{field}: nothing found for #{id}")
      end
    end
  end
end
