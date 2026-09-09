# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Webhooks
    # Fans events out to deliveries: one webhook_deliveries row per event per endpoint
    # that is subscribed to it when the event is dispatched.
    #
    # It walks the events outbox in `seq` order from a stored cursor. The hard part is
    # that seq order is not commit order. Transaction A draws seq 10, transaction B
    # draws seq 11 and commits first; a dispatcher that reads 11 and moves its cursor
    # there has skipped 10 for good once A commits. So the cursor only moves past a seq
    # once every transaction that could still be holding a lower one has ended:
    #
    # 1. Each pass fans out every event visible above the cursor. Fan-out is idempotent
    #    (UNIQUE (event_id, endpoint_id), ON CONFLICT DO NOTHING), so scanning an event
    #    twice is harmless and nothing waits on the cursor to be delivered.
    # 2. In the same statement it records a barrier: the highest seq it saw, and the
    #    snapshot's xmax, the first transaction id not yet started.
    # 3. A later pass moves the cursor to the barrier once pg_snapshot_xmin of a fresh
    #    snapshot is at or past that xmax: every transaction that was running when the
    #    barrier was taken has committed or rolled back, so every seq at or below the
    #    barrier is final, and the scan in that same pass has seen all of them.
    #
    # This needs each event's transaction to hold a transaction id before it draws its
    # seq, which Events.emit! ensures with pg_current_xact_id(). A rolled-back seq
    # leaves a gap that is simply passed over. A transaction left open for an hour holds
    # the cursor back for an hour, which costs rescanning, not correctness.
    #
    # Only one dispatcher does a pass at a time (the cursor row is locked), and a pass
    # is one short transaction. Several dispatcher processes are safe, just not faster.
    class Dispatcher
      extend T::Sig

      DEFAULT_NAME = 'default'

      # What one pass did.
      class Pass < T::Struct
        const :scanned, Integer
        const :created, Integer
        const :cursor, Integer
        const :expired, Integer

        extend T::Sig

        sig { returns(T::Boolean) }
        def idle? = scanned.zero? && expired.zero?
      end

      # The next batch of events above the cursor, each joined to the endpoints that
      # should receive it (or to NULL if none should, so the seq still counts as seen),
      # and the snapshot's xmax, read in the same statement so it describes exactly
      # the snapshot the batch was read with.
      SCAN_SQL = <<~SQL
        WITH batch AS (
          SELECT id, merchant_id, type, created_at, seq
          FROM events
          WHERE seq > :cursor
          ORDER BY seq
          LIMIT :limit
        )
        SELECT b.seq, b.id AS event_id, b.created_at AS event_created_at, e.id AS endpoint_id,
               pg_snapshot_xmax(pg_current_snapshot())::text AS xmax
        FROM batch b
        LEFT JOIN webhook_endpoints e
          ON e.merchant_id = b.merchant_id
         AND e.deleted_at IS NULL
         AND e.status = 'enabled'
         AND e.created_at <= b.created_at
         AND (e.enabled_events @> '["*"]' OR e.enabled_events @> jsonb_build_array(b.type))
        ORDER BY b.seq
      SQL

      # Where the cursor may move once every transaction older than xmax has ended.
      class Barrier < T::Struct
        const :seq, Integer
        const :xmax, String
      end

      # What a scan found: how many events, the highest seq, and the snapshot xmax.
      class Scan < T::Struct
        const :scanned, Integer
        const :high, T.nilable(Integer)
        const :xmax, T.nilable(String)
      end

      sig do
        params(db: Sequel::Database, clock: Clock, retry_policy: RetryPolicy, batch_size: Integer,
               name: String).void
      end
      def initialize(db:, clock:, retry_policy: RetryPolicy.new, batch_size: 500, name: DEFAULT_NAME)
        @db = db
        @clock = clock
        @retry_policy = retry_policy
        @batch_size = batch_size
        @name = name
      end

      sig { returns(Pass) }
      def run_once
        now = @clock.now
        @db.transaction do
          state = lock_state
          passed = barrier_passed?(state)
          rows = @db.fetch(SCAN_SQL, cursor: state[:cursor_seq], limit: @batch_size).all
          created = fan_out(rows, now)
          scan = Scan.new(scanned: rows.map { |row| row[:seq] }.uniq.length, high: rows.last&.fetch(:seq),
                          xmax: rows.first&.fetch(:xmax))
          cursor = advance(state, scan, passed)
          Pass.new(scanned: scan.scanned, created: created, cursor: cursor, expired: expire_overdue(now))
        end
      end

      # Runs passes until one finds nothing new. For tests and the experiment driver.
      sig { params(max_passes: Integer).returns(T::Array[Pass]) }
      def run_until_idle(max_passes: 1000)
        passes = []
        max_passes.times do
          pass = run_once
          passes << pass
          break if pass.scanned < @batch_size && pass.created.zero?
        end
        passes
      end

      private

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def lock_state
        @db[:webhook_dispatch_cursors].insert_conflict.insert(name: @name)
        @db[:webhook_dispatch_cursors].where(name: @name).for_update.first.to_h
      end

      # True when every transaction that was running when the barrier was set has
      # ended. Our own transaction started after the barrier was stored, so its id is
      # at or past barrier_xmax and cannot hold the comparison back.
      sig { params(state: T::Hash[Symbol, T.untyped]).returns(T::Boolean) }
      def barrier_passed?(state)
        return false if state[:barrier_seq].nil?

        @db.get(Sequel.lit('pg_snapshot_xmin(pg_current_snapshot()) >= ?::xid8', state[:barrier_xmax].to_s)) == true
      end

      # Inserts a delivery for every (event, endpoint) pair that does not have one yet.
      # Returns how many were new.
      sig { params(rows: T::Array[T::Hash[Symbol, T.untyped]], now: Time).returns(Integer) }
      def fan_out(rows, now)
        deadline = @retry_policy.deadline_for(now)
        pairs = rows.select { |row| row[:endpoint_id] }.map do |row|
          { id: Ids.generate('whd'), event_id: row[:event_id], endpoint_id: row[:endpoint_id],
            event_created_at: row[:event_created_at], created_at: now, next_attempt_at: now,
            retry_deadline_at: deadline }
        end
        return 0 if pairs.empty?

        @db[:webhook_deliveries].insert_conflict(target: %i[event_id endpoint_id])
                                .multi_insert(pairs, return: :primary_key).length
      end

      # Moves the cursor as far as is safe and sets the next barrier. Returns the cursor.
      sig { params(state: T::Hash[Symbol, T.untyped], scan: Scan, passed: T::Boolean).returns(Integer) }
      def advance(state, scan, passed)
        cursor = state[:cursor_seq].to_i
        barrier = if state[:barrier_seq]
                    Barrier.new(seq: state[:barrier_seq].to_i,
                                xmax: state[:barrier_xmax].to_s)
                  end
        if passed && barrier
          cursor = reachable(barrier.seq, scan)
          barrier = nil if cursor == barrier.seq
        end
        # Keep an existing barrier until it passes rather than moving it forward, or a
        # steady stream of new transactions could keep pushing it out of reach.
        high = scan.high
        barrier = Barrier.new(seq: high, xmax: T.must(scan.xmax)) if barrier.nil? && high && high > cursor
        @db[:webhook_dispatch_cursors].where(name: @name).update(
          cursor_seq: cursor, barrier_seq: barrier&.seq, updated_at: @clock.now,
          barrier_xmax: barrier && Sequel.cast(barrier.xmax, :xid8)
        )
        cursor
      end

      # Everything at or below a passed barrier is final and was visible to this pass's
      # scan. If the batch was full it may have stopped short of the barrier, and the
      # cursor can only go as far as the batch reached.
      sig { params(barrier_seq: Integer, scan: Scan).returns(Integer) }
      def reachable(barrier_seq, scan)
        high = scan.high
        full = scan.scanned >= @batch_size
        full && high && high < barrier_seq ? high : barrier_seq
      end

      # A delivery can sit pending past its retry window without being attempted, for
      # example while its endpoint's circuit breaker is open. Those are failed here,
      # unless a worker holds a live lease on them.
      sig { params(now: Time).returns(Integer) }
      def expire_overdue(now)
        @db[:webhook_deliveries]
          .where(status: 'pending')
          .where(Sequel.lit('retry_deadline_at < ?', now))
          .where(Sequel.lit('lease_expires_at IS NULL OR lease_expires_at <= ?', now))
          .update(status: 'failed', failed_at: now, last_error: 'retry_window_elapsed')
      end
    end
  end
end
