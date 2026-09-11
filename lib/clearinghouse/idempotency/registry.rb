# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Idempotency
    # Every flow, by name. The completer finds a key's flow here, and the crash
    # experiment enumerates every recovery point of every flow from here, so a
    # flow added to the registry is recoverable and crash-tested without anyone
    # remembering to add it anywhere else.
    class Registry
      extend T::Sig

      class UnknownFlowError < Clearinghouse::Error; end

      # One place a process can be made to crash: right after the phase that
      # reaches `point` commits, or just before it commits.
      class CrashPoint < T::Struct
        const :flow, String
        const :point, String
        const :moment, Symbol # :after_commit or :before_commit

        extend T::Sig

        sig { returns(String) }
        def to_s
          moment == :after_commit ? "#{flow}:#{point}" : "#{flow}:#{point}:before_commit"
        end
      end

      MOMENTS = %i[after_commit before_commit].freeze

      sig { params(flows: T::Array[Flow]).void }
      def initialize(flows = [])
        @flows = T.let({}, T::Hash[String, Flow])
        flows.each { |f| register(f) }
      end

      sig { params(flow: Flow).returns(T.self_type) }
      def register(flow)
        flow.validate!
        raise ArgumentError, "flow #{flow.name} is already registered" if @flows.key?(flow.name)

        @flows[flow.name] = flow
        self
      end

      sig { params(name: String).returns(Flow) }
      def fetch(name)
        @flows.fetch(name) { raise UnknownFlowError, "no flow named #{name.inspect}" }
      end

      sig { returns(T::Array[Flow]) }
      def flows
        @flows.values
      end

      # Every (flow, recovery point, moment) there is.
      sig { returns(T::Array[CrashPoint]) }
      def crash_points
        flows.flat_map do |flow|
          flow.recovery_points.product(MOMENTS).map do |point, moment|
            CrashPoint.new(flow: flow.name, point: point, moment: moment)
          end
        end
      end
    end
  end
end
