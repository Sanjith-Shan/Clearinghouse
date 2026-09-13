# typed: true
# frozen_string_literal: true

require 'json'
require 'securerandom'

module Clearinghouse
  module Webhooks
    # Delivers one webhook at a time: claim, send, record.
    #
    # 1. Claim (short transaction): the queue picks a due delivery with
    #    FOR UPDATE SKIP LOCKED and stamps a lease on it.
    # 2. Send (no transaction open): render the event at the endpoint's pinned API
    #    version, sign it with the endpoint's active secrets at the clock's time, and
    #    POST it through SafeHttp.
    # 3. Record (short transaction): success, a retry at the backoff schedule, or
    #    failure, and the endpoint's health.
    #
    # Delivery is at least once. A worker can die after the endpoint has answered 200
    # and before step 3 commits; the lease then expires, another worker claims the
    # delivery, and the endpoint receives it again. Nothing on the sending side can
    # close that window, because "the endpoint processed it" and "we wrote that down"
    # are two systems, so consumers dedupe on the event id.
    class Worker
      extend T::Sig

      SIGNATURE_HEADER = Signature::HEADER

      # What happened to one claimed delivery.
      class Result < T::Struct
        const :delivery_id, String
        const :endpoint_id, String
        # :succeeded, :retrying, :failed, or :lease_lost (a failure recorded by nobody,
        # because another worker had taken the delivery over).
        const :state, Symbol
        const :outcome, T.nilable(Egress::Outcome)
        const :duration_ms, Integer
      end

      sig { returns(String) }
      attr_reader :name

      sig do
        params(db: Sequel::Database, clock: Clock, http: SafeHttp, queue: Queue, retry_policy: RetryPolicy,
               rng: Random, lease_seconds: Numeric, versioning: Versioning::Engine, name: String,
               log: T.nilable(T.any(IO, StringIO))).void
      end
      def initialize(db:, clock:, http:, queue: FifoQueue.new, retry_policy: RetryPolicy.new, rng: Random.new,
                     lease_seconds: 60, versioning: Versioning.engine, name: "worker-#{SecureRandom.hex(4)}",
                     log: nil)
        @db = db
        @clock = clock
        @http = http
        @queue = queue
        @retry_policy = retry_policy
        @rng = rng
        @lease_seconds = lease_seconds
        @versioning = versioning
        @name = name
        @log = log
      end

      # Claims and delivers one webhook. nil when nothing is due.
      sig { returns(T.nilable(Result)) }
      def work_once
        claim = @queue.claim(@db, now: @clock.now, lease_seconds: @lease_seconds,
                                  token: "#{@name}:#{SecureRandom.hex(8)}")
        return nil unless claim

        deliver(claim)
      end

      # Works until nothing is due. For tests.
      sig { params(limit: Integer).returns(T::Array[Result]) }
      def drain(limit: 10_000)
        results = []
        limit.times do
          result = work_once
          break unless result

          results << result
        end
        results
      end

      sig { params(claim: Claim).returns(Result) }
      def deliver(claim)
        endpoint_row = @db[:webhook_endpoints].where(id: claim.endpoint_id).first
        endpoint = Endpoints.from_row(T.must(endpoint_row))
        unless endpoint.enabled? && endpoint_row&.fetch(:deleted_at).nil?
          return record_final(claim, reason: endpoint.enabled? ? 'endpoint_deleted' : 'endpoint_disabled')
        end

        attempt(claim, endpoint)
      end

      private

      sig { params(claim: Claim, endpoint: Endpoint).returns(Result) }
      def attempt(claim, endpoint)
        started = monotonic_ms
        begin
          outcome = send_request(claim, endpoint)
          record(claim, outcome, monotonic_ms - started)
        rescue StandardError => e
          # Our bug (a render error, say), not the endpoint's. Retry on the normal
          # schedule, and keep it out of the endpoint's health. A failure while
          # recording lands here too, and is recorded as a retry if the database allows.
          record_internal_error(claim, e, monotonic_ms - started)
        end
      end

      sig { params(claim: Claim, endpoint: Endpoint).returns(Egress::Outcome) }
      def send_request(claim, endpoint)
        event = @db[:events].where(id: claim.event_id).first
        payload = @versioning.render_event(Clearinghouse::Events.envelope(T.must(event)), endpoint.api_version)
        body = JSON.generate(payload)
        now = @clock.now
        header = Signature.sign(payload: body, secrets: endpoint.secrets.active_secrets(now: now),
                                timestamp: now.to_i)
        @http.post(endpoint.url, body: body, headers: { SIGNATURE_HEADER => header })
      end

      sig { params(claim: Claim, outcome: Egress::Outcome, duration_ms: Integer).returns(Result) }
      def record(claim, outcome, duration_ms)
        state = @db.transaction do
          now = @clock.now
          case outcome
          when Egress::Outcome::Delivered
            record_success(claim, outcome, duration_ms, now)
          else
            # A blocked URL will be just as blocked next time, so it is not retried.
            failed = Failed.new(status: status_of(outcome), error: T.must(describe(outcome)),
                                retry: !outcome.is_a?(Egress::Outcome::Blocked), endpoint_at_fault: true)
            record_failure(claim, failed, duration_ms, now)
          end
        end
        result = Result.new(delivery_id: claim.delivery_id, endpoint_id: claim.endpoint_id, state: state,
                            outcome: outcome, duration_ms: duration_ms)
        log(result, claim)
        result
      end

      # A 2xx is recorded whoever holds the lease now: the endpoint has the event, and
      # that is the fact that matters. Clearing the lease also means a worker that took
      # this delivery over and failed will find its token gone and record nothing.
      sig do
        params(claim: Claim, outcome: Egress::Outcome::Delivered, duration_ms: Integer, now: Time).returns(Symbol)
      end
      def record_success(claim, outcome, duration_ms, now)
        @db[:webhook_deliveries].where(id: claim.delivery_id).exclude(status: 'succeeded').update(
          status: 'succeeded', succeeded_at: now, failed_at: nil, lease_token: nil, lease_expires_at: nil,
          last_status: outcome.status, last_error: nil, last_duration_ms: duration_ms
        )
        EndpointHealth.success(@db, claim.endpoint_id)
        :succeeded
      end

      # A failed attempt, however it failed.
      class Failed < T::Struct
        const :status, T.nilable(Integer)
        const :error, String
        const :retry, T::Boolean
        const :endpoint_at_fault, T::Boolean
      end

      # A failure only counts if we still hold the lease; otherwise another worker owns
      # the retry schedule. The endpoint's health hears about it either way.
      sig { params(claim: Claim, failed: Failed, duration_ms: Integer, now: Time).returns(Symbol) }
      def record_failure(claim, failed, duration_ms, now)
        next_at = if failed.retry
                    @retry_policy.next_attempt_at(claim.attempts, now: now, deadline: claim.retry_deadline_at,
                                                                  rng: @rng)
                  end
        changes = { lease_token: nil, lease_expires_at: nil, last_status: failed.status,
                    last_error: failed.error, last_duration_ms: duration_ms }
        changes.merge!(next_at ? { next_attempt_at: next_at } : { status: 'failed', failed_at: now })
        owned = @db[:webhook_deliveries].where(id: claim.delivery_id, status: 'pending',
                                               lease_token: claim.lease_token).update(changes)
        health = failed.endpoint_at_fault ? EndpointHealth.failure(@db, claim.endpoint_id, clock: @clock) : nil
        disabled = health == :disabled
        return :lease_lost if owned.zero?

        # Disabling the endpoint just failed this delivery along with its other pending ones.
        next_at && !disabled ? :retrying : :failed
      end

      sig { params(claim: Claim, error: StandardError, duration_ms: Integer).returns(Result) }
      def record_internal_error(claim, error, duration_ms)
        failed = Failed.new(status: nil, error: "internal_error: #{error.class}: #{error.message}".slice(0, 500).to_s,
                            retry: true, endpoint_at_fault: false)
        state = @db.transaction { record_failure(claim, failed, duration_ms, @clock.now) }
        @log&.puts(JSON.generate({ 'worker' => @name, 'delivery' => claim.delivery_id, 'level' => 'error',
                                   'exception' => error.class.name, 'message' => error.message,
                                   'backtrace' => error.backtrace&.first(5) }))
        Result.new(delivery_id: claim.delivery_id, endpoint_id: claim.endpoint_id, state: state, outcome: nil,
                   duration_ms: duration_ms)
      end

      # The endpoint was disabled or deleted after this delivery was claimed.
      sig { params(claim: Claim, reason: String).returns(Result) }
      def record_final(claim, reason:)
        @db[:webhook_deliveries].where(id: claim.delivery_id, status: 'pending', lease_token: claim.lease_token)
                                .update(status: 'failed', failed_at: @clock.now, last_error: reason,
                                        lease_token: nil, lease_expires_at: nil)
        Result.new(delivery_id: claim.delivery_id, endpoint_id: claim.endpoint_id, state: :failed, outcome: nil,
                   duration_ms: 0)
      end

      sig { params(outcome: Egress::Outcome).returns(T.nilable(Integer)) }
      def status_of(outcome)
        case outcome
        when Egress::Outcome::Delivered, Egress::Outcome::Rejected then outcome.status
        end
      end

      sig { params(outcome: Egress::Outcome).returns(T.nilable(String)) }
      def describe(outcome)
        case outcome
        when Egress::Outcome::Delivered then nil
        when Egress::Outcome::Rejected then "http_#{outcome.status}"
        when Egress::Outcome::Timeout then "timeout_#{outcome.phase}"
        when Egress::Outcome::ConnectionFailed then "connection_failed: #{outcome.message}"[0, 500]
        when Egress::Outcome::Blocked then "blocked: #{outcome.reason}: #{outcome.detail}"[0, 500]
        else T.absurd(outcome)
        end
      end

      sig { params(result: Result, claim: Claim).void }
      def log(result, claim)
        return unless @log

        @log.puts(JSON.generate({ 'worker' => @name, 'delivery' => result.delivery_id, 'event' => claim.event_id,
                                  'endpoint' => result.endpoint_id, 'attempt' => claim.attempts,
                                  'state' => result.state, 'error' => (outcome = result.outcome) && describe(outcome),
                                  'duration_ms' => result.duration_ms, 'at' => @clock.now.utc.iso8601(3) }))
      end

      # Durations are measured on the monotonic clock: they describe this process's
      # wall time, not simulated time.
      sig { returns(Integer) }
      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
      end
    end
  end
end
