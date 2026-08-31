# typed: true
# frozen_string_literal: true

require 'json'

module Clearinghouse
  module Versioning
    # Renders objects at a requested API version.
    #
    # 1. Copy the latest-shape object, so the caller's hash is never touched.
    # 2. Expand the caller's `expand[]` paths, then every field a skipped change
    #    forces to be embedded. Expansion always works on the latest shape.
    # 3. For each change newer than the requested version, newest first, walk the
    #    whole tree and transform every object whose `object` is one of the
    #    change's resources: at the top, in a list's `data`, in an event's
    #    `data.object`, or inside another object.
    #
    # The walk skips `metadata`, which is merchant data: a merchant who stores
    # {"object": "payment_intent"} there must not have it rewritten.
    class Engine
      extend T::Sig

      class UnknownVersionError < Clearinghouse::Error; end
      class ProtectedFieldError < Clearinghouse::Error; end
      class InvalidExpansionError < Clearinghouse::Error; end

      # Fields no version change may alter, agreed with RiskGate, which reads them
      # from webhooks at whatever version its endpoint is pinned to. `object` is
      # here too because the walk itself depends on it.
      PROTECTED_FIELDS = %w[id object amount currency payment_intent reason status].freeze

      SKIPPED_KEYS = %w[metadata].freeze

      sig { returns(Registry) }
      attr_reader :registry

      sig { returns(Expander) }
      attr_reader :expander

      sig { params(registry: Registry, expander: Expander).void }
      def initialize(registry:, expander:)
        @registry = registry
        @expander = expander
      end

      sig { returns(String) }
      def latest = @registry.latest

      sig { returns(T::Array[String]) }
      def versions = @registry.versions

      sig { params(version: String).returns(T::Boolean) }
      def known?(version) = @registry.known?(version)

      sig { params(object: Json, version: String, expand: T::Array[String], context: T.untyped).returns(Json) }
      def render(object, version, expand: [], context: nil)
        changes = changes_for!(version)
        copy = deep_copy(object)
        expand.each { |path| expand_path!(copy, path.split('.'), path, context) }
        changes.each do |change|
          change.forced_expansions.each { |resource, field| force_expansion!(copy, resource, field, context) }
        end
        changes.reduce(copy) { |tree, change| apply(change, tree) }
      end

      # Webhook payloads: the event envelope says which version it was rendered at,
      # and its data.object is walked back like any response.
      sig { params(event: Json, version: String, context: T.untyped).returns(Json) }
      def render_event(event, version, context: nil)
        render(event.merge('api_version' => version), version, context: context)
      end

      # Rewrites an old caller's request parameters into the latest shape. Changes
      # apply oldest first, walking forward from the caller's version.
      sig { params(endpoint: String, params: Json, version: String).returns(Json) }
      def transform_request(endpoint, params, version)
        changes_for!(version).reverse.reduce(deep_copy(params)) do |current, change|
          change.request_endpoints.include?(endpoint) ? change.transform_request(endpoint, current) : current
        end
      end

      # For changes with side effects: true when a caller on `version` still gets
      # the behaviour from before `change_class` shipped.
      sig { params(change_class: T::Class[VersionChange], version: String).returns(T::Boolean) }
      def legacy?(change_class, version)
        changes_for!(version)
        version < @registry.find(change_class).version
      end

      private

      sig { params(version: String).returns(T::Array[VersionChange]) }
      def changes_for!(version)
        raise UnknownVersionError, "unknown API version #{version.inspect}" unless known?(version)

        @registry.changes_after(version)
      end

      sig { params(change: VersionChange, node: T.untyped).returns(T.untyped) }
      def apply(change, node)
        case node
        when Array then node.map { |child| apply(change, child) }
        when Hash
          walked = node.to_h { |key, value| [key, SKIPPED_KEYS.include?(key) ? value : apply(change, value)] }
          change.resources.include?(walked['object']) ? transform_one(change, walked) : walked
        else node
        end
      end

      sig { params(change: VersionChange, object: Json).returns(Json) }
      def transform_one(change, object)
        before = object.slice(*PROTECTED_FIELDS)
        result = change.transform(object)
        unless result.slice(*PROTECTED_FIELDS) == before
          raise ProtectedFieldError, "#{change.class} changed a protected field on #{object['object']}"
        end

        result
      end

      # Expands one caller-supplied path such as "payment_method" or
      # "data.latest_charge.balance_transaction". Each segment but the last may
      # itself be an expandable id, which is expanded on the way down.
      sig { params(node: T.untyped, segments: T::Array[String], path: String, context: T.untyped).void }
      def expand_path!(node, segments, path, context)
        return if node.nil?
        return node.each { |child| expand_path!(child, segments, path, context) } if node.is_a?(Array)

        field = T.must(segments.first)
        raise InvalidExpansionError, path unless node.is_a?(Hash) && node.key?(field)

        expand_field!(node, field, context) if @expander.expandable?(node['object'], field)
        value = node[field]
        if segments.length == 1
          raise InvalidExpansionError, path unless value.nil? || value.is_a?(Hash)
        else
          expand_path!(value, segments.drop(1), path, context)
        end
      end

      sig { params(node: T.untyped, resource: String, field: String, context: T.untyped).void }
      def force_expansion!(node, resource, field, context)
        case node
        when Array then node.each { |child| force_expansion!(child, resource, field, context) }
        when Hash
          expand_field!(node, field, context) if node['object'] == resource
          node.each { |key, value| force_expansion!(value, resource, field, context) unless SKIPPED_KEYS.include?(key) }
        end
      end

      sig { params(node: Json, field: String, context: T.untyped).void }
      def expand_field!(node, field, context)
        id = node[field]
        return unless id.is_a?(String)

        node[field] = @expander.load(node.fetch('object'), field, id, context)
      end

      sig { params(object: T.untyped).returns(T.untyped) }
      def deep_copy(object)
        case object
        when Hash then object.to_h { |key, value| [key, deep_copy(value)] }
        when Array then object.map { |value| deep_copy(value) }
        else object
        end
      end
    end
  end
end
