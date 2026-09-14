# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Balances
    # When a captured payment's net stops being pending and can be paid out.
    #
    # The capture calls `schedule!` inside its own transaction, next to the capture's
    # ledger posting, so a payment that captured always has exactly one row here.
    # `release_due!` is a sweep driven by the clock: it posts the availability
    # transaction (merchant pending -> merchant available) for every row whose
    # `available_on` has passed, and marks the row released in the same database
    # transaction. See docs/design/payouts.md.
    module Availability
      extend T::Sig

      TABLE = :scheduled_availabilities

      # One scheduled release, as stored.
      class Scheduled < T::Struct
        const :id, Integer
        const :flow_id, String
        const :merchant_id, String
        const :net, Money
        const :available_on, Time
        const :released_at, T.nilable(Time)
        const :released_to, T.nilable(String)
      end

      # What one sweep did.
      class ReleaseReport < T::Struct
        const :released, T::Array[Scheduled]

        extend T::Sig

        sig { params(destination: String).returns(Integer) }
        def count(destination)
          released.count { |s| s.released_to == destination }
        end
      end

      # A second schedule! for the same flow with different terms. The first one
      # stands; this means a caller computed the net twice and got two answers.
      class ConflictError < Clearinghouse::Error; end

      class MerchantNotFoundError < Clearinghouse::Error; end

      # The start of the UTC day `delay_days` after the capture, as Stripe's
      # `available_on` is a date. A capture at 23:59 and one at 00:01 the same day
      # become available together, which is what a merchant reading a balance
      # statement expects.
      sig { params(db: Sequel::Database, merchant_id: String, captured_at: Time).returns(Time) }
      def self.available_on_for(db, merchant_id:, captured_at:)
        delay = db[:merchants].where(id: merchant_id).get(:payout_delay_days)
        raise MerchantNotFoundError, "no merchant #{merchant_id}" if delay.nil?

        day = captured_at.utc
        Time.utc(day.year, day.month, day.day) + (Integer(delay) * Clock::SECONDS_PER_DAY)
      end

      # Records that `net` of this payment becomes available on `available_on`.
      # Call it inside the capture's transaction. Idempotent: calling it again with
      # the same terms returns the existing row, so a capture phase that is retried
      # after a crash cannot schedule the money twice. A zero net (the fee ate the
      # whole payment) schedules nothing, since there is nothing to release.
      sig do
        params(db: Sequel::Database, flow_id: String, merchant_id: String, net: Money, available_on: Time,
               clock: Clock).returns(T.nilable(Scheduled))
      end
      def self.schedule!(db, flow_id:, merchant_id:, net:, available_on:, clock:)
        raise ArgumentError, "net must not be negative, got #{net}" if net.negative?
        return nil if net.zero?

        inserted = db.fetch(<<~SQL, flow_id, merchant_id, net.amount, net.currency, available_on, clock.now).first
          INSERT INTO scheduled_availabilities (flow_id, merchant_id, amount, currency, available_on, created_at)
          VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (flow_id) DO NOTHING RETURNING *
        SQL
        return from_row(inserted) if inserted

        existing = T.must(find(db, flow_id))
        unless existing.merchant_id == merchant_id && existing.net == net && existing.available_on == available_on
          raise ConflictError, "#{flow_id} is already scheduled as #{existing.net} for #{existing.merchant_id} " \
                               "on #{existing.available_on.iso8601}"
        end
        existing
      end

      sig { params(db: Sequel::Database, flow_id: String).returns(T.nilable(Scheduled)) }
      def self.find(db, flow_id)
        row = db[TABLE].where(flow_id: flow_id).first
        row ? from_row(row) : nil
      end

      # The same row, locked FOR UPDATE until the caller's transaction ends, or nil
      # if the payment has no release scheduled. Holds use it to serialize with the
      # sweep over one payment's money.
      sig { params(db: Sequel::Database, flow_id: String).returns(T.nilable(Scheduled)) }
      def self.find_for_update(db, flow_id)
        raise Clearinghouse::Error, 'find_for_update needs an open database transaction' unless db.in_transaction?

        row = db[TABLE].where(flow_id: flow_id).for_update.first
        row ? from_row(row) : nil
      end

      # Releases everything due by the clock's now, in batches. Each batch is one
      # database transaction that claims its rows with FOR UPDATE SKIP LOCKED, posts
      # one ledger transaction per row and sets `released_at`. So:
      #
      # - a crash anywhere in a batch rolls back its postings and its marks together,
      #   and the next sweep picks the same rows up again;
      # - two sweeps running at once claim disjoint rows and never wait on each other;
      # - a row is never released twice, because it is only claimed while
      #   `released_at IS NULL`, and the mark commits with the posting.
      sig { params(db: Sequel::Database, clock: Clock, batch_size: Integer).returns(ReleaseReport) }
      def self.release_due!(db, clock:, batch_size: 200)
        now = clock.now
        released = T.let([], T::Array[Scheduled])
        loop do
          batch = T.let(db.transaction { release_batch(db, now, batch_size) }, T::Array[Scheduled])
          released.concat(batch)
          break if batch.length < batch_size
        end
        ReleaseReport.new(released: released)
      end

      sig { params(db: Sequel::Database, now: Time, batch_size: Integer).returns(T::Array[Scheduled]) }
      def self.release_batch(db, now, batch_size)
        rows = db[TABLE].where(released_at: nil).where(Sequel.lit('available_on <= ?', now))
                        .order(:available_on, :id).limit(batch_size).for_update.skip_locked.all
        rows.map { |row| release(db, from_row(row), now) }
      end
      private_class_method :release_batch

      # Posts the availability transaction for one claimed row and marks it. The
      # posting is dated at the row's `available_on`, not at the sweep's now: the
      # money became available on that day even if the sweep ran late. A payment
      # under risk review goes to held instead (see Holds), and its hold records
      # the amount in the same transaction.
      sig { params(db: Sequel::Database, scheduled: Scheduled, now: Time).returns(Scheduled) }
      def self.release(db, scheduled, now)
        held = Holds.withholds?(db, scheduled.flow_id)
        merchant_id = scheduled.merchant_id
        entries = if held
                    Ledger::Flows.funds_held(merchant_id: merchant_id, net: scheduled.net)
                  else
                    Ledger::Flows.funds_available(merchant_id: merchant_id, net: scheduled.net)
                  end
        txn = Ledger.post!(db, flow_type: Ledger::Flows::PAYMENT, flow_id: scheduled.flow_id,
                               description: held ? 'funds held for review' : 'funds available',
                               effective_at: scheduled.available_on, entries: entries)
        Holds.record_held!(db, scheduled.flow_id, scheduled.net) if held
        mark_released(db, scheduled, now, held ? 'held' : 'available', txn)
      end
      private_class_method :release

      sig do
        params(db: Sequel::Database, scheduled: Scheduled, now: Time, destination: String,
               txn: Integer).returns(Scheduled)
      end
      def self.mark_released(db, scheduled, now, destination, txn)
        rows = db[TABLE].where(id: scheduled.id, released_at: nil).returning
                        .update(released_at: now, released_to: destination, release_transaction_id: txn)
        # Unreachable while the row is locked; a loud failure beats a silent double release.
        raise Clearinghouse::Error, "availability #{scheduled.id} was released concurrently" unless rows.length == 1

        from_row(rows.fetch(0))
      end
      private_class_method :mark_released

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(Scheduled) }
      def self.from_row(row)
        Scheduled.new(id: Integer(row.fetch(:id)), flow_id: row.fetch(:flow_id), merchant_id: row.fetch(:merchant_id),
                      net: Money.of(Integer(row.fetch(:amount)), row.fetch(:currency)),
                      available_on: row.fetch(:available_on).utc, released_at: row[:released_at]&.utc,
                      released_to: row[:released_to])
      end
      private_class_method :from_row
    end
  end
end
