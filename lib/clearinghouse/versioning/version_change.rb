# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Versioning
    # One backwards-incompatible change to the API, in the style Brandur Leach
    # describes for Stripe ("APIs as infrastructure", 2017): a self-contained module
    # that says when the change shipped, what it changed in words, which resource
    # types it touches, and how to turn the new shape back into the old one.
    #
    # Stripe's modules use a small DSL. These are plain method overrides instead,
    # so Sorbet checks every change against this interface.
    #
    # Core code only ever builds the latest shape. The engine runs each change newer
    # than the caller's version, newest first, over every object of a declared type
    # anywhere in the response: top level, inside a list, inside an event's
    # data.object, or expanded inside another object.
    class VersionChange
      extend T::Sig
      extend T::Helpers

      abstract!

      # The first version with the new behaviour, as YYYY-MM-DD. Callers pinned
      # before this date get `transform`'s output.
      sig { abstract.returns(String) }
      def version; end

      # One or two sentences for the changelog, written for an API user.
      sig { abstract.returns(String) }
      def description; end

      # The `object` values this change applies to, e.g. ["payment_intent"].
      sig { abstract.returns(T::Array[String]) }
      def resources; end

      # Takes an object of one of `resources` in the shape at `version` and returns
      # it in the shape just before `version`. Receives a copy; may mutate it.
      sig { abstract.params(object: Json).returns(Json) }
      def transform(object); end

      # Fields that were always embedded before this change and became expandable
      # ids with it, as [resource, field] pairs. The engine expands them before any
      # transform runs, so old versions get the object without the transform having
      # to load anything.
      sig { returns(T::Array[[String, String]]) }
      def forced_expansions = []

      # Request-side hook, for a change that renamed or reshaped a request
      # parameter. Old callers still send the old shape; this rewrites it into the
      # new one before the endpoint reads it. `endpoint` names the operation, e.g.
      # "payment_intents.capture".
      sig { returns(T::Array[String]) }
      def request_endpoints = []

      sig { params(endpoint: String, params: Json).returns(Json) }
      def transform_request(endpoint, params) # rubocop:disable Lint/UnusedMethodArgument
        params
      end

      # A change whose old behaviour is business logic, not just a different shape
      # (Stripe calls these `has_side_effects`). Its transform is the identity, and
      # the code that behaves differently asks `Engine#legacy?(ThisChange, version)`.
      sig { returns(T::Boolean) }
      def side_effects? = false

      # Renames a key in place, keeping key order so rendered JSON stays readable.
      sig { params(object: Json, from: String, to: String).returns(Json) }
      def self.rename_key(object, from, to)
        return object unless object.key?(from)

        object.to_h { |key, value| [key == from ? to : key, value] }
      end
    end
  end
end
