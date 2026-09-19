# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Acquirer
    # Reads the acquirer's notification feed and hands each notification to the
    # handler registered for its type, so that its effects happen exactly once.
    #
    # "Exactly once" is built from two at-least-once pieces. The feed can repeat
    # itself (a cursor that did not move because we crashed, two pollers, a replayed
    # page), so every notification is handled in one database transaction that also
    # inserts its id into processed_notifications and moves the cursor. The insert is
    # the gate: if the id is already there, the effects already committed and the
    # handler is skipped. If the transaction rolls back, neither the effects nor the
    # row nor the cursor exist, and the next poll sees the notification again.
    #
    # Notifications are handled strictly in feed order, and a failure stops the poll
    # there. A dispute.closed must never be applied before its dispute.opened, and a
    # notification nobody can handle is never skipped: skipping would lose money
    # information for good, while stopping is loud and loses nothing.
    class NotificationPoller
      extend T::Sig

      # Applies one notification's effects. Runs inside the poller's database
      # transaction, so it must not commit on its own.
      Handler = T.type_alias { T.proc.params(db: Sequel::Database, notification: Notification).void }

      # Where a crash can land, in order. `notification_fetched`: read from the feed,
      # nothing written. `effects_written`: everything written, not yet committed.
      # `committed`: committed, the next notification not started. The crash matrix in
      # spec/settlement/notification_poller_spec.rb runs every one of them in process,
      # and experiment 2 runs them against a real bin/poller per notification type
      # (Settlement.background_crash_points).
      RECOVERY_POINTS = %w[notification_fetched effects_written committed].freeze

      # Called at each recovery point with the point and the type of the notification
      # being handled, so a test can crash on one type and not another.
      CrashHook = T.type_alias { T.proc.params(point: String, type: String).void }

      # The flow name a notification type's recovery points go by in crash names:
      # `notification.dispute.opened:effects_written`.
      sig { params(type: String).returns(String) }
      def self.flow_name(type)
        "notification.#{type}"
      end

      # Adapts the idempotency framework's hook (armed from CLEARINGHOUSE_CRASH_AT in
      # test and experiment environments, DISARMED otherwise) to the poller's. Each
      # point is one crash moment and its name already says which side of the commit
      # it is on, so every name is the plain `<flow>:<point>` form.
      sig { params(hook: Idempotency::CrashHook).returns(CrashHook) }
      def self.crash_hook(hook)
        ->(point, type) { hook.reached(flow_name(type), point, :after_commit) }
      end

      class UnhandledNotificationError < Clearinghouse::Error; end

      # Handlers by notification type. Each area registers its own: disputes for
      # dispute.*, payouts for payout.*.
      class Handlers
        extend T::Sig

        sig { void }
        def initialize
          @handlers = T.let({}, T::Hash[String, Handler])
        end

        sig { params(type: String, handler: Handler).returns(Handlers) }
        def register(type, &handler)
          raise ArgumentError, "a handler for #{type} is already registered" if @handlers.key?(type)

          @handlers[type] = handler
          self
        end

        sig { params(type: String).returns(Handler) }
        def fetch(type)
          @handlers.fetch(type) do
            raise UnhandledNotificationError, "no handler registered for #{type} notifications"
          end
        end

        sig { returns(T::Array[String]) }
        def types
          @handlers.keys.sort
        end
      end

      # What one poll did. `unavailable` is set when the acquirer could not be reached;
      # nothing is lost, the next poll picks up from `cursor`.
      class Result < T::Struct
        const :processed, Integer
        const :already_processed, Integer
        const :cursor, String
        const :unavailable, T.nilable(String)
      end

      sig do
        params(db: Sequel::Database, client: Client, clock: Clock, handlers: Handlers, name: String,
               crash_hook: T.nilable(CrashHook)).void
      end
      def initialize(db:, client:, clock:, handlers:, name: 'acquirer', crash_hook: nil)
        @db = db
        @client = client
        @clock = clock
        @handlers = handlers
        @name = name
        @crash_hook = crash_hook
      end

      # Handles everything due by the clock's now, page by page. Raises the first
      # handler error, leaving the cursor on the last notification that committed.
      sig { returns(Result) }
      def poll
        cursor = self.cursor
        processed = 0
        repeated = 0
        loop do
          page = @client.notifications(after: cursor)
          if page.is_a?(Unavailable)
            return Result.new(processed: processed, already_processed: repeated, cursor: cursor,
                              unavailable: page.reason)
          end
          break if page.data.empty?

          page.data.each do |notification|
            handle(notification) ? processed += 1 : repeated += 1
            cursor = notification.cursor
          end
        end
        Result.new(processed: processed, already_processed: repeated, cursor: cursor)
      end

      # The stored cursor, "0" (the start of the feed) for a consumer that has never read.
      sig { returns(String) }
      def cursor
        @db[:acquirer_cursors].insert_conflict.insert(name: @name, cursor: '0', updated_at: @clock.now)
        T.cast(@db[:acquirer_cursors].where(name: @name).get(:cursor), String)
      end

      private

      # True when this call applied the notification, false when an earlier one had.
      sig { params(notification: Notification).returns(T::Boolean) }
      def handle(notification)
        handler = @handlers.fetch(notification.type) # before any write: an unknown type stops here
        crash!('notification_fetched', notification)
        fresh = T.let(@db.transaction do
          first = claimed?(notification)
          handler.call(@db, notification) if first
          @db[:acquirer_cursors].where(name: @name).update(cursor: notification.cursor, updated_at: @clock.now)
          crash!('effects_written', notification)
          first
        end, T::Boolean)
        crash!('committed', notification)
        fresh
      end

      # Inserts the notification's row. Returns false if it was already there, which
      # means its effects committed earlier. A concurrent poller inserting the same id
      # blocks here on the primary key until the first commits, then gets false.
      sig { params(notification: Notification).returns(T::Boolean) }
      def claimed?(notification)
        rows = @db[:processed_notifications].insert_conflict.returning(:id).insert(
          id: notification.id, type: notification.type, cursor: notification.cursor,
          data: Sequel.cast(JSON.generate(notification.data), :json), occurred_at: notification.created_at,
          processed_at: @clock.now
        )
        !rows.empty?
      end

      sig { params(point: String, notification: Notification).void }
      def crash!(point, notification)
        @crash_hook&.call(point, notification.type)
      end
    end
  end
end
