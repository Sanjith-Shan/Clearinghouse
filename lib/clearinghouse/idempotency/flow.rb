# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Idempotency
    STARTED = 'started'
    FINISHED = 'finished'

    # What a request sent back, stored so a retry gets exactly the same thing.
    class Response < T::Struct
      extend T::Sig

      const :status, Integer
      const :body, String
      const :headers, T::Hash[String, String], default: {}

      # Value equality: a replay is correct when it equals what was first sent.
      sig { params(other: T.untyped).returns(T::Boolean) }
      def ==(other)
        return false unless other.is_a?(Response)

        [status, body, headers] == [other.status, other.body, other.headers]
      end
    end

    # Turns a flow's result into the bytes a client receives. The API supplies
    # one per request (it knows the API version and expand[]); `options` is what
    # it needs to be rebuilt by a process that never saw the request, and is
    # stored with the key.
    module Renderer
      extend T::Sig
      extend T::Helpers

      interface!

      sig { abstract.params(object: T::Hash[String, T.untyped], status: Integer).returns(Response) }
      def render(object, status: 200); end

      # A final answer for an error: the same request would fail the same way, so
      # it is stored and replayed. nil means the error is not final (a 5xx, an
      # object busy right now): nothing is stored and the request can be retried.
      sig { abstract.params(error: StandardError).returns(T.nilable(Response)) }
      def error_response(error); end

      sig { abstract.returns(T::Hash[String, T.untyped]) }
      def options; end
    end

    # One execution of a flow, handed to every phase.
    class Run
      extend T::Sig

      # The operation's collaborators (the request Context in the API). Opaque here.
      sig { returns(T.untyped) }
      attr_reader :context

      sig { returns(T::Struct) }
      attr_reader :input

      # The idempotency key row's id. Flows use it to mark what they own.
      sig { returns(Integer) }
      attr_reader :key_id

      # Values one phase leaves for later ones (a refund id). Persisted with the
      # recovery point, in the same transaction.
      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :state

      sig { returns(Renderer) }
      attr_reader :renderer

      # True while the phase being run was loaded from the database rather than
      # reached in this process: the previous attempt got at least this far and
      # then stopped, so any foreign call this phase makes may already have been
      # made. Phases use it to ask before they act.
      sig { returns(T::Boolean) }
      attr_accessor :resumed

      sig do
        params(context: T.untyped, input: T::Struct, key_id: Integer, state: T::Hash[String, T.untyped],
               renderer: Renderer, resumed: T::Boolean).void
      end
      def initialize(context:, input:, key_id:, state:, renderer:, resumed:)
        @context = context
        @input = input
        @key_id = key_id
        @state = state
        @renderer = renderer
        @resumed = resumed
      end

      sig { params(object: T::Hash[String, T.untyped], status: Integer).returns(Response) }
      def render(object, status: 200)
        renderer.render(object, status: status)
      end

      # The stored response for an error that ends the request (a decline).
      sig { params(error: StandardError).returns(Response) }
      def render_error(error)
        renderer.error_response(error) || raise(ArgumentError, "#{error.class} is not a final answer")
      end
    end

    # One atomic phase. `foreign`, if present, runs first and outside any
    # transaction: it is where a call to another system goes. `atomic` then runs
    # in one SERIALIZABLE transaction, with the foreign call's result, and that
    # same transaction moves the recovery point from `from` to `to`. It returns
    # nil to advance, or a Response to finish the request there.
    #
    # `atomic` may be run more than once (a serialization failure retries it), so
    # it must only touch the database. `foreign` runs once per attempt at the
    # phase, and again if the request is resumed at `from`, so the call it makes
    # must be idempotent on the other side, or asked about first (Run#resumed).
    class Phase < T::Struct
      const :from, String
      const :to, String
      const :foreign, T.nilable(T.proc.params(run: Run).returns(T.untyped)), default: nil
      const :atomic, T.proc.params(run: Run, db: Sequel::Database, foreign: T.untyped).returns(T.nilable(Response))
    end

    # An operation as a chain of phases from `started` to `finished`. Subclasses
    # are stateless singletons listed in a Registry, and a key row names its flow,
    # so anything that can read the row can finish the work.
    class Flow
      extend T::Sig
      extend T::Helpers

      abstract!

      class DefinitionError < Clearinghouse::Error; end

      # Stored on the key row; must never change once keys exist under it.
      sig { abstract.returns(String) }
      def name; end

      sig { abstract.returns(T::Array[Phase]) }
      def phases; end

      # The input struct, rebuilt from its serialized form on the key row.
      sig { abstract.params(hash: T::Hash[String, T.untyped]).returns(T::Struct) }
      def load_input(hash); end

      # Runs in the transaction that finishes the request, whichever phase
      # finishes it and whether it succeeded or stored an error. Flows release
      # anything they hold across phases here.
      sig { overridable.params(run: Run, db: Sequel::Database).void }
      def release(run, db); end

      # Every recovery point, in order. Generated from the phases, so there is no
      # second list to forget to update.
      sig { returns(T::Array[String]) }
      def recovery_points
        [STARTED] + phases.map(&:to)
      end

      sig { params(point: String).returns(Phase) }
      def phase_from(point)
        phases.find { |p| p.from == point } || raise(DefinitionError, "#{name} has no phase from #{point}")
      end

      # The phases must form one chain from started to finished.
      sig { void }
      def validate!
        points = phases.map(&:from) + [T.must(phases.last).to]
        chained = phases.each_cons(2).all? { |a, b| T.must(a).to == T.must(b).from }
        return if chained && points.first == STARTED && points.last == FINISHED && points.uniq.length == points.length

        got = phases.map { |p| "#{p.from} -> #{p.to}" }.join(', ')
        raise DefinitionError, "#{name}: phases must chain started -> ... -> finished, got #{got}"
      end
    end
  end
end
