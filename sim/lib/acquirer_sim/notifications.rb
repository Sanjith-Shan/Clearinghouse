# typed: true
# frozen_string_literal: true

module AcquirerSim
  # The feed behind GET /notifications. Callers hold the simulator's mutex.
  #
  # The cursor is the subtle part. Notifications are created in one order (seq) but
  # become visible in another (due_at), and a notification can be created *after* a
  # poll with a due time *before* that poll (a dispute resolved at an earlier
  # Sim-Time by a caller whose test clock lags). A cursor over seq or over due_at
  # would skip something in one of those cases. So the cursor is assigned at the
  # moment a poll first sees a notification: each poll stamps every newly visible
  # notification with the next number, in (due_at, seq) order, and returns those
  # past the caller's cursor. Every notification gets exactly one cursor, cursors
  # only grow, and a consumer that follows next_cursor sees each notification once.
  class Notifications
    extend T::Sig

    DEFAULT_LIMIT = 100

    # One page of the feed.
    class Page < T::Struct
      const :data, T::Array[Notification]
      const :next_cursor, Integer
    end

    sig { void }
    def initialize
      @all = T.let([], T::Array[Notification])
      @last_cursor = T.let(0, Integer)
    end

    sig { params(type: String, subject: String, due_at: Time, data: T::Hash[String, T.untyped]).returns(Notification) }
    def schedule(type, subject, due_at, data)
      notification = Notification.new(id: Ids.derive('ntf', type, subject), type: type, due_at: due_at,
                                      seq: @all.size, data: data)
      @all << notification
      notification
    end

    sig { params(after: Integer, sim_time: Time, limit: Integer).returns(Page) }
    def page(after:, sim_time:, limit: DEFAULT_LIMIT)
      @all.select { |n| n.cursor.nil? && n.due_at <= sim_time }
          .sort_by { |n| [n.due_at, n.seq] }
          .each { |n| n.cursor = (@last_cursor += 1) }
      data = @all.select { |n| (cursor = n.cursor) && cursor > after }.sort_by { |n| T.must(n.cursor) }.first(limit)
      Page.new(data: data, next_cursor: data.last&.cursor || after)
    end
  end
end
