# typed: true
# frozen_string_literal: true

module Experiments
  module Isolation
    # What an operation sees of the database inside one transaction. The only
    # thing a strategy changes about it is whether reads lock the row.
    class Tx
      extend T::Sig

      sig { params(db: Sequel::Database, lock: T::Boolean, pause: T.nilable(T.proc.void)).void }
      def initialize(db, lock:, pause: nil)
        @db = db
        @lock = lock
        @pause = pause
      end

      sig { params(table: Symbol, id: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def read(table, id)
        rows = @db[table].where(id: id)
        rows = rows.for_update if @lock
        T.must(rows.first)
      end

      # Writes absolute values computed from what was read, the way an ORM's
      # load-modify-save does. Every write bumps the row's version, so a write that
      # overwrote another one shows up afterwards as a version that moved less than
      # the number of writes (Audit).
      sig { params(table: Symbol, row: T::Hash[Symbol, T.untyped], changes: Integer).void }
      def write(table, row, **changes)
        @db[table].where(id: row.fetch(:id)).update(changes.merge(version: row.fetch(:version) + 1))
      end

      sig do
        params(kind: String, amount: Integer, balance: T::Hash[Symbol, T.untyped],
               payment: T.nilable(T::Hash[Symbol, T.untyped])).void
      end
      def log(kind, amount, balance:, payment: nil)
        @db[:iso_movements].insert(kind: kind, amount: amount, payment_id: payment&.fetch(:id),
                                   payment_version_read: payment&.fetch(:version),
                                   balance_version_read: balance.fetch(:version))
      end

      # The gap between reading and writing. Nothing happens here in a timed run;
      # the spec uses it to force two transactions to interleave in a known order.
      sig { void }
      def pause
        @pause&.call
      end
    end

    # The four operations, written once. Each strategy runs the same code; only
    # the transaction around it differs.
    module Operations
      extend T::Sig

      MERCHANT = 1

      # A partial refund. It comes out of the merchant's available balance
      # (docs/design/ledger.md), so it touches both rows: the payment first, then
      # the balance, the same order everywhere so FOR UPDATE cannot deadlock.
      sig { params(txn: Tx, payment_id: Integer, amount: Integer).returns(Symbol) }
      def self.refund(txn, payment_id, amount)
        payment = txn.read(:iso_payments, payment_id)
        balance = txn.read(:iso_balances, MERCHANT)
        txn.pause
        return :declined if payment.fetch(:amount_received) - payment.fetch(:amount_refunded) < amount

        txn.write(:iso_payments, payment, amount_refunded: payment.fetch(:amount_refunded) + amount)
        txn.write(:iso_balances, balance, available: balance.fetch(:available) - amount)
        txn.log('refund', amount, payment: payment, balance: balance)
        :applied
      end

      # Pays out everything available. Blocked at zero or below (docs/design/ledger.md).
      sig { params(txn: Tx).returns(Symbol) }
      def self.payout(txn)
        balance = txn.read(:iso_balances, MERCHANT)
        txn.pause
        amount = balance.fetch(:available)
        return :declined unless amount.positive?

        txn.write(:iso_balances, balance, available: 0)
        txn.log('payout', amount, balance: balance)
        :applied
      end

      # The network has decided a dispute, so it is never refused, and it may take
      # the balance negative (the merchant then owes us).
      sig { params(txn: Tx, amount: Integer).returns(Symbol) }
      def self.dispute(txn, amount)
        balance = txn.read(:iso_balances, MERCHANT)
        txn.pause
        txn.write(:iso_balances, balance, available: balance.fetch(:available) - amount)
        txn.log('dispute', amount, balance: balance)
        :applied
      end

      # Earlier captures becoming available. Keeps the balance refilling so payouts
      # keep having something to pay.
      sig { params(txn: Tx, amount: Integer).returns(Symbol) }
      def self.credit(txn, amount)
        balance = txn.read(:iso_balances, MERCHANT)
        txn.pause
        txn.write(:iso_balances, balance, available: balance.fetch(:available) + amount)
        txn.log('credit', amount, balance: balance)
        :applied
      end
    end

    # The three strategies. `run` yields a Tx and returns the operation's result
    # and how many attempts it took.
    module Strategies
      extend T::Sig

      Block = T.type_alias { T.proc.params(txn: Tx).returns(Symbol) }
      Pause = T.type_alias { T.nilable(T.proc.void) }

      # Raised when SERIALIZABLE gives up on an operation.
      class RetriesExhausted < StandardError
        extend T::Sig

        sig { returns(Integer) }
        attr_reader :attempts

        sig { params(attempts: Integer).void }
        def initialize(attempts)
          @attempts = attempts
          super("gave up after #{attempts} attempts")
        end
      end

      # READ COMMITTED, plain SELECT, then UPDATE with what was read.
      class ReadThenWrite
        extend T::Sig

        sig { returns(String) }
        def name = 'rc_read_then_write'

        sig { params(db: Sequel::Database, pause: Pause, blk: Block).returns([Symbol, Integer]) }
        def run(db, pause: nil, &blk)
          [db.transaction(isolation: :committed) { yield Tx.new(db, lock: false, pause: pause) }, 1]
        end
      end

      # READ COMMITTED, SELECT ... FOR UPDATE: the second reader waits for the
      # first to commit and then reads its result.
      class ForUpdate
        extend T::Sig

        sig { returns(String) }
        def name = 'rc_for_update'

        sig { params(db: Sequel::Database, pause: Pause, blk: Block).returns([Symbol, Integer]) }
        def run(db, pause: nil, &blk)
          [db.transaction(isolation: :committed) { yield Tx.new(db, lock: true, pause: pause) }, 1]
        end
      end

      # SERIALIZABLE, plain SELECT; Postgres aborts one side of a conflict with
      # 40001 (or 40P01 on a deadlock, which Sequel raises as the same class), and
      # the whole transaction runs again after a jittered backoff.
      #
      # With `lock: true` it also reads FOR UPDATE, which is what the idempotency
      # layer's atomic phases do (a SERIALIZABLE transaction around code that
      # locks the intent). The lock makes the second transaction wait instead of
      # racing, but it still gets 40001 once the first commits, because its
      # snapshot is older than the row it locked.
      class SerializableRetry
        extend T::Sig

        sig { returns(Integer) }
        attr_reader :max_attempts

        sig { params(lock: T::Boolean, max_attempts: Integer, base_sleep: Float, max_sleep: Float).void }
        def initialize(lock: false, max_attempts: 10, base_sleep: 0.001, max_sleep: 0.05)
          @lock = lock
          @max_attempts = max_attempts
          @base_sleep = base_sleep
          @max_sleep = max_sleep
        end

        sig { returns(String) }
        def name = @lock ? 'serializable_for_update' : 'serializable_retry'

        sig { params(db: Sequel::Database, pause: Pause, blk: Block).returns([Symbol, Integer]) }
        def run(db, pause: nil, &blk)
          attempts = 0
          begin
            attempts += 1
            [db.transaction(isolation: :serializable) { yield Tx.new(db, lock: @lock, pause: pause) }, attempts]
          rescue Sequel::SerializationFailure
            raise RetriesExhausted, attempts if attempts >= @max_attempts

            # Full jitter: a random wait up to an exponentially growing cap, so the
            # transactions that just collided do not collide again in lockstep.
            sleep(Random.rand * [@max_sleep, @base_sleep * (2**attempts)].min)
            retry
          end
        end
      end

      ALL = T.let([ReadThenWrite.new, ForUpdate.new, SerializableRetry.new,
                   SerializableRetry.new(lock: true)].freeze,
                  T::Array[T.any(ReadThenWrite, ForUpdate, SerializableRetry)])

      Strategy = T.type_alias { T.any(ReadThenWrite, ForUpdate, SerializableRetry) }

      sig { params(name: String).returns(Strategy) }
      def self.named(name)
        ALL.find { |s| s.name == name } || raise(ArgumentError, "unknown strategy #{name}")
      end
    end
  end
end
