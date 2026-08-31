# typed: true
# frozen_string_literal: true

require 'date'

module Clearinghouse
  module Versioning
    # The list of versions and the changes that separate them. A version exists
    # because a change shipped on that date, plus the initial version the API
    # started at. Several changes may share a date.
    class Registry
      extend T::Sig

      class InvalidRegistryError < Clearinghouse::Error; end

      DATE = /\A\d{4}-\d{2}-\d{2}\z/

      sig { returns(String) }
      attr_reader :initial

      sig { returns(T::Array[VersionChange]) }
      attr_reader :changes

      sig { params(initial: String, changes: T::Array[VersionChange]).void }
      def initialize(initial:, changes:)
        @initial = initial
        @changes = T.let(changes.sort_by(&:version).freeze, T::Array[VersionChange])
        validate!
        @versions = T.let([initial, *@changes.map(&:version)].uniq.freeze, T::Array[String])
      end

      sig { returns(T::Array[String]) }
      attr_reader :versions

      sig { returns(String) }
      def latest = T.must(@versions.last)

      sig { params(version: String).returns(T::Boolean) }
      def known?(version) = @versions.include?(version)

      # The changes a caller on `version` has not seen, newest first: the order
      # responses are walked back in.
      sig { params(version: String).returns(T::Array[VersionChange]) }
      def changes_after(version)
        @changes.select { |change| change.version > version }.reverse
      end

      sig { params(klass: T::Class[VersionChange]).returns(VersionChange) }
      def find(klass)
        @changes.find { |change| change.is_a?(klass) } || raise(ArgumentError, "#{klass} is not registered")
      end

      private

      sig { void }
      def validate!
        ([@initial] + @changes.map(&:version)).each do |date|
          raise InvalidRegistryError, "#{date.inspect} is not YYYY-MM-DD" unless DATE.match?(date) && valid_date?(date)
        end
        @changes.each do |change|
          if change.version <= @initial
            raise InvalidRegistryError,
                  "#{change.class} (#{change.version}) is not after the initial version #{@initial}"
          end
          raise InvalidRegistryError, "#{change.class} declares no resources" if change.resources.empty?
        end
      end

      sig { params(date: String).returns(T::Boolean) }
      def valid_date?(date)
        Date.iso8601(date)
        true
      rescue Date::Error
        false
      end
    end
  end
end
