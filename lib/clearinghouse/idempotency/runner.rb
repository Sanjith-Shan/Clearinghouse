# typed: strict
# frozen_string_literal: true

require 'securerandom'

module Clearinghouse
  module Idempotency
    # Same key, different request.
    class KeyReusedError < Clearinghouse::Error
      extend T::Sig

      sig { returns(String) }
      attr_reader :key

      sig { params(key: String).void }
      def initialize(key)
        super("idempotency key #{key} was first used with different parameters")
        @key = key
      end
    end

    # Same key while the first request still holds it.
    class KeyInUseError < Clearinghouse::Error
      extend T::Sig

      sig { returns(String) }
      attr_reader :key

      sig { params(key: String).void }
      def initialize(key)
        super("idempotency key #{key} is in use by a request that is still running")
        @key = key
      end
    end

    # Runs a flow under an idempotency key. The contract (docs/design/idempotency.md):
    #
    # - A new key runs the flow from `started`.
    # - A finished key returns its stored response, whatever happened since.
    # - A key first used with other parameters raises KeyReusedError.
    # - A key held by a live runner raises KeyInUseError. Nothing waits and nothing
    #   runs twice.
    # - A key whose runner stopped (its lease expired, or it gave the lease back
    #   after a retryable error) resumes from its recovery point.
    # - A finished key older than KEY_TTL is gone: the key starts afresh.
    #
    # A request without a key gets a generated one. Nobody can replay it, but its
    # row still records how far it got, so the completer can finish it.
    class Runner
      extend T::Sig

      KEY_TTL = T.let(24 * 60 * 60, Integer)
      DEFAULT_LOCK_TIMEOUT = 60

      # What the request looked like, for the key row.
      class Request < T::Struct
        const :merchant_id, String
        const :key, T.nilable(String)
        const :http_method, String
        const :path, String
        const :params, T::Hash[String, T.untyped]
        const :request_id, String
      end

      # What to send back, and whether it is a replay of an earlier request's answer.
      class Result < T::Struct
        const :response, Response
        const :replayed, T::Boolean
        # The request that produced the response, when replayed.
        const :original_request_id, String
      end

      sig { returns(Numeric) }
      attr_reader :lock_timeout

      sig do
        params(db: Sequel::Database, clock: Clock, lock_timeout: Numeric, policy: Serializable::Policy,
               crash_hook: CrashHook).void
      end
      def initialize(db:, clock:, lock_timeout: DEFAULT_LOCK_TIMEOUT, policy: Serializable::Policy.new,
                     crash_hook: CrashHook::DISARMED)
        @db = db
        @clock = clock
        @lock_timeout = lock_timeout
        @policy = policy
        @crash_hook = crash_hook
      end

      sig do
        params(flow: Flow, input: T::Struct, request: Request, context: T.untyped, renderer: Renderer).returns(Result)
      end
      def call(flow:, input:, request:, context:, renderer:)
        token = SecureRandom.hex(16)
        record, fresh = acquire(new_key(flow, input, request, renderer), token)
        return replay(record) if record.finished?

        drive(flow, record, token, context, renderer, resumed: !fresh)
      end

      # Picks up a key by id, for the completer: the same lease rules as a
      # request, and it always resumes.
      sig { params(registry: Registry, id: Integer, context: T.untyped, renderer: Renderer).returns(Result) }
      def resume(registry:, id:, context:, renderer:)
        token = SecureRandom.hex(16)
        record = Serializable.transaction(@db, policy: @policy) do
          found = @db[Store::TABLE].where(id: id).for_update.first
          raise ArgumentError, "no idempotency key #{id}" unless found

          current = Record.from_row(found)
          next current if current.finished?
          raise KeyInUseError, current.key if current.locked?(@clock.now, @lock_timeout)

          Store.lease(@db, current, token, @clock.now)
        end
        return replay(record) if record.finished?

        drive(registry.fetch(record.flow), record, token, context, renderer, resumed: true)
      end

      private

      # The row a new key gets, minus the times and the lease.
      sig do
        params(flow: Flow, input: T::Struct, request: Request, renderer: Renderer).returns(T::Hash[Symbol, T.untyped])
      end
      def new_key(flow, input, request, renderer)
        {
          merchant_id: request.merchant_id, key: request.key || "auto_#{request.request_id}",
          client_supplied: !request.key.nil?, flow: flow.name, flow_input: input.serialize,
          request_method: request.http_method.upcase, request_path: request.path,
          request_fingerprint: Fingerprint.compute(method: request.http_method, path: request.path,
                                                   params: request.params),
          request_id: request.request_id, render_options: renderer.options, recovery_point: STARTED
        }
      end

      # The key row, leased to us, and whether we created it. Two requests racing
      # to create the same key collide on the unique index (or as a serialization
      # failure); the loser looks again and finds the winner's row.
      sig { params(attributes: T::Hash[Symbol, T.untyped], token: String).returns([Record, T::Boolean]) }
      def acquire(attributes, token)
        attempts = 0
        begin
          attempts += 1
          fresh = T.let(false, T::Boolean)
          record = Serializable.transaction(@db, policy: @policy) do
            now = @clock.now
            existing = live_key(attributes, now)
            next take_existing(existing, attributes.fetch(:request_fingerprint), token, now) if existing

            fresh = true
            created = Store.insert(@db, attributes.merge(locked_at: now, lock_token: token, last_run_at: now,
                                                         created_at: now))
            @crash_hook.reached(created.flow, STARTED, :before_commit)
            created
          end
        rescue Sequel::UniqueConstraintViolation
          raise if attempts >= 3

          retry
        end
        @crash_hook.reached(record.flow, STARTED, :after_commit) if fresh
        [record, fresh]
      end

      # The key's row, locked, unless there is none or it finished more than
      # KEY_TTL ago and the reaper has not got to it yet, which is as good as gone.
      sig { params(attributes: T::Hash[Symbol, T.untyped], now: Time).returns(T.nilable(Record)) }
      def live_key(attributes, now)
        existing = Store.find_for_update(@db, attributes.fetch(:merchant_id), attributes.fetch(:key))
        return existing unless existing&.finished? && existing.created_at <= now - KEY_TTL

        Store.delete(@db, existing.id)
        nil
      end

      sig { params(existing: Record, fingerprint: String, token: String, now: Time).returns(Record) }
      def take_existing(existing, fingerprint, token, now)
        check_existing!(existing, fingerprint, now)
        return existing if existing.finished?

        Store.lease(@db, existing, token, now)
      end

      sig { params(existing: Record, fingerprint: String, now: Time).void }
      def check_existing!(existing, fingerprint, now)
        raise KeyReusedError, existing.key unless existing.request_fingerprint == fingerprint
        return if existing.finished?

        raise KeyInUseError, existing.key if existing.locked?(now, @lock_timeout)
      end

      sig { params(record: Record).returns(Result) }
      def replay(record)
        Result.new(response: T.must(record.response), replayed: true, original_request_id: record.request_id)
      end

      sig do
        params(flow: Flow, record: Record, token: String, context: T.untyped, renderer: Renderer,
               resumed: T::Boolean).returns(Result)
      end
      def drive(flow, record, token, context, renderer, resumed:)
        run = Run.new(context: context, input: flow.load_input(record.flow_input), key_id: record.id,
                      state: record.flow_state, renderer: renderer, resumed: resumed)
        point = record.recovery_point
        loop do
          phase = flow.phase_from(point)
          response = run_phase(flow, phase, run, token)
          return Result.new(response: response, replayed: false, original_request_id: record.request_id) if response

          point = phase.to
          run.resumed = false
        end
      end

      # One phase: the foreign call, if any, then the atomic transaction. An error
      # the renderer calls final (a 4xx) finishes the key with that response. Any
      # other error gives the lease back, so a retry can resume at once instead of
      # waiting for it to expire, and propagates.
      sig { params(flow: Flow, phase: Phase, run: Run, token: String).returns(T.nilable(Response)) }
      def run_phase(flow, phase, run, token)
        foreign = phase.foreign&.call(run)
        commit(flow, phase, run, token, foreign)
      rescue StandardError => e
        final = run.renderer.error_response(e)
        if final.nil?
          give_back(run.key_id, token)
          raise
        end
        finish_with(flow, phase.from, run, token, final)
      end

      sig do
        params(flow: Flow, phase: Phase, run: Run, token: String, foreign: T.untyped).returns(T.nilable(Response))
      end
      def commit(flow, phase, run, token, foreign)
        committed_state = run.state.dup
        response = Serializable.transaction(@db, policy: @policy) do
          # A retried attempt starts from the committed state, not from what the
          # rolled-back attempt left in memory.
          run.state.replace(committed_state.dup)
          result = phase.atomic.call(run, @db, foreign)
          if result
            flow.release(run, @db)
            Store.finish!(@db, run.key_id, token, from: phase.from, response: result, state: run.state, now: @clock.now)
          else
            if phase.to == FINISHED
              raise Flow::DefinitionError, "#{flow.name}: the phase to finished must return a response"
            end

            Store.advance!(@db, run.key_id, token, from: phase.from, to: phase.to, state: run.state, now: @clock.now)
          end
          @crash_hook.reached(flow.name, result ? FINISHED : phase.to, :before_commit)
          result
        end
        @crash_hook.reached(flow.name, response ? FINISHED : phase.to, :after_commit)
        response
      end

      sig { params(flow: Flow, from: String, run: Run, token: String, response: Response).returns(Response) }
      def finish_with(flow, from, run, token, response)
        Serializable.transaction(@db, policy: @policy) do
          flow.release(run, @db)
          Store.finish!(@db, run.key_id, token, from: from, response: response, state: run.state, now: @clock.now)
          @crash_hook.reached(flow.name, FINISHED, :before_commit)
        end
        @crash_hook.reached(flow.name, FINISHED, :after_commit)
        response
      end

      # Best effort: if the database is what failed, the lease simply expires.
      sig { params(id: Integer, token: String).void }
      def give_back(id, token)
        @db.transaction { Store.release(@db, id, token) }
      rescue Sequel::Error
        nil
      end
    end
  end
end
