# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Idempotency
    # Makes atomic phases that write the same hot row take turns *before* their
    # SERIALIZABLE transactions begin.
    #
    # A `SELECT ... FOR UPDATE` inside a SERIALIZABLE transaction queues writers
    # on a row, but it does not stop them aborting: the waiter's snapshot was
    # taken before the winner committed, so when the lock is granted Postgres
    # raises 40001 anyway (docs/design/isolation.md). With N requests on one row,
    # the last in line can lose N - 1 times in a row, and past the retry budget
    # that is a failed request. A session-level advisory lock taken on the phase's
    # connection before BEGIN moves the wait ahead of the snapshot: each phase
    # starts after the previous one committed, sees its writes, and does not
    # conflict with it at all.
    #
    # The lock is held only for the atomic step, which touches nothing but the
    # database, never across a foreign call. If the process dies holding it, the
    # connection closes and Postgres releases it.
    module Turnstile
      extend T::Sig

      sig do
        type_parameters(:R)
          .params(db: Sequel::Database, key: String, block: T.proc.returns(T.type_parameter(:R)))
          .returns(T.type_parameter(:R))
      end
      def self.through(db, key, &block)
        raise Clearinghouse::Error, 'a turnstile must be passed before the transaction begins' if db.in_transaction?

        # Sequel hands this thread the same connection for everything inside
        # synchronize, so the lock, the transaction and the unlock share a session.
        db.synchronize do
          lock_id = Sequel.function(:hashtextextended, key, 0)
          db.get(Sequel.function(:pg_advisory_lock, lock_id))
          begin
            block.call
          ensure
            unlock(db, lock_id)
          end
        end
      end

      # A lost connection has already released the lock; saying so again would
      # only hide the error that got us here.
      sig { params(db: Sequel::Database, lock_id: Sequel::SQL::Function).void }
      def self.unlock(db, lock_id)
        db.get(Sequel.function(:pg_advisory_unlock, lock_id))
      rescue Sequel::DatabaseDisconnectError
        nil
      end
      private_class_method :unlock
    end
  end
end
