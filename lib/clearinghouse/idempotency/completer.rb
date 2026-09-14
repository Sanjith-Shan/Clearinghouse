# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Idempotency
    # Drives abandoned requests to completion. A request is abandoned when its key
    # is unfinished and nobody is working on it: its lease expired (the process
    # died, or stalled past the lease) or it gave the lease back after a
    # retryable error (the acquirer did not answer) and no retry has come for a
    # while. The completer resumes each one exactly as a client retry would,
    # through Runner#resume, so it needs no knowledge of any flow beyond the
    # registry: a flow registered there is completed here.
    #
    # Several completers can run at once. Each candidate is resumed under the
    # same lease rules as a request, so two of them (or a completer and a
    # client) never run one key at the same time; the loser gets KeyInUseError
    # and moves on.
    class Completer
      extend T::Sig

      # Rebuilds whatever a flow needs for one key (the merchant's context, a
      # renderer at the stored version) and resumes it.
      Resumer = T.type_alias { T.proc.params(record: Record).returns(Runner::Result) }

      # What one pass did.
      class Report < T::Struct
        const :completed, T::Array[Integer], default: []
        const :busy, T::Array[Integer], default: []
        # Key id and the error, for keys that could not be finished this pass
        # (the acquirer still not answering). They stay where they are and are
        # tried again next pass.
        const :failed, T::Array[[Integer, String]], default: []
      end

      sig do
        params(db: Sequel::Database, clock: Clock, lock_timeout: Numeric, grace: Numeric, resumer: Resumer).void
      end
      def initialize(db:, clock:, lock_timeout:, grace:, resumer:)
        @db = db
        @clock = clock
        @lock_timeout = lock_timeout
        @grace = grace
        @resumer = resumer
      end

      # Unfinished keys nobody holds, whose last run is at least `grace` ago,
      # oldest first. The grace period leaves room for a client that was told to
      # retry to do so itself.
      sig { params(limit: Integer).returns(T::Array[Record]) }
      def candidates(limit: 100)
        now = @clock.now
        @db[Store::TABLE].exclude(recovery_point: FINISHED)
                         .where(Sequel.lit('locked_at IS NULL OR locked_at <= ?', now - @lock_timeout))
                         .where(Sequel.lit('last_run_at <= ?', now - @grace))
                         .order(:last_run_at, :id).limit(limit).map { |row| Record.from_row(row) }
      end

      sig { params(limit: Integer).returns(Report) }
      def run_once(limit: 100)
        report = Report.new
        candidates(limit: limit).each do |record|
          @resumer.call(record)
          report.completed << record.id
        rescue KeyInUseError, LockLostError
          report.busy << record.id
        rescue StandardError => e
          report.failed << [record.id, "#{e.class}: #{e.message}"]
        end
        report
      end
    end

    # Deletes finished keys older than the 24 hour window. Unfinished keys are
    # never deleted, however old: each one is a request the completer still owes
    # an ending, and deleting it would lose the only record of how far it got.
    # The reaper counts them instead, for an operator to look at.
    module Reaper
      extend T::Sig

      # Keys deleted, and unfinished keys past the window that were left alone.
      class Report < T::Struct
        const :deleted, Integer
        const :stuck, Integer
      end

      sig { params(db: Sequel::Database, clock: Clock, ttl: Integer).returns(Report) }
      def self.run(db, clock:, ttl: Runner::KEY_TTL)
        cutoff = clock.now - ttl
        deleted = db[Store::TABLE].where(recovery_point: FINISHED).where(Sequel.lit('created_at <= ?', cutoff)).delete
        stuck = db[Store::TABLE].exclude(recovery_point: FINISHED).where(Sequel.lit('created_at <= ?', cutoff)).count
        Report.new(deleted: deleted, stuck: stuck)
      end
    end
  end
end
