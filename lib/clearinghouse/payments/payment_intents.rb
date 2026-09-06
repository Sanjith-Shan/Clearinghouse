# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # Reading and writing payment_intents rows. Every read is scoped to a merchant:
    # another merchant's intent is "not found", never "forbidden", so ids cannot be
    # probed across accounts.
    module PaymentIntents
      extend T::Sig

      # Someone else changed the row between our read and our write. Inside a
      # SERIALIZABLE phase with the row locked this cannot happen, so it means a
      # caller skipped the lock, and it fails loudly rather than overwriting.
      class StaleError < Clearinghouse::Error; end

      sig { params(db: Sequel::Database, intent: PaymentIntent).returns(PaymentIntent) }
      def self.insert!(db, intent)
        db[:payment_intents].insert(intent.to_row)
        intent
      end

      sig { params(db: Sequel::Database, merchant_id: String, id: String).returns(T.nilable(PaymentIntent)) }
      def self.find(db, merchant_id:, id:)
        row = db[:payment_intents].where(merchant_id: merchant_id, id: id).first
        row ? PaymentIntent.from_row(row) : nil
      end

      sig { params(db: Sequel::Database, merchant_id: String, id: String, param: String).returns(PaymentIntent) }
      def self.find!(db, merchant_id:, id:, param: 'intent')
        find(db, merchant_id: merchant_id, id: id) ||
          raise(Api::Errors::NotFoundError.resource('payment_intent', id, param: param))
      end

      # The row, locked FOR UPDATE until the caller's transaction ends.
      sig { params(db: Sequel::Database, merchant_id: String, id: String, param: String).returns(PaymentIntent) }
      def self.lock!(db, merchant_id:, id:, param: 'intent')
        raise Clearinghouse::Error, 'lock! needs an open transaction' unless db.in_transaction?

        row = db[:payment_intents].where(merchant_id: merchant_id, id: id).for_update.first
        raise Api::Errors::NotFoundError.resource('payment_intent', id, param: param) unless row

        PaymentIntent.from_row(row)
      end

      # Writes `after` over `before`, bumping lock_version, and returns what was
      # written. `updated_at` comes from the caller's clock.
      sig { params(db: Sequel::Database, before: PaymentIntent, after: PaymentIntent, now: Time).returns(PaymentIntent) }
      def self.save!(db, before, after, now:)
        raise ArgumentError, 'cannot change an intent into another one' unless before.id == after.id

        saved = after.copy(lock_version: before.lock_version + 1, updated_at: now)
        count = db[:payment_intents].where(id: before.id, lock_version: before.lock_version)
                                    .update(saved.to_row.except(:id, :merchant_id, :created_at))
        raise StaleError, "#{before.id} changed under us (lock_version #{before.lock_version})" unless count == 1

        saved
      end

      # One page, newest first. `starting_after` is the id of the last intent on the
      # previous page, as in Stripe's cursor pagination.
      sig do
        params(db: Sequel::Database, merchant_id: String, limit: Integer,
               starting_after: T.nilable(String)).returns([T::Array[PaymentIntent], T::Boolean])
      end
      def self.list(db, merchant_id:, limit:, starting_after: nil)
        scope = db[:payment_intents].where(merchant_id: merchant_id)
        if starting_after
          cursor = find!(db, merchant_id: merchant_id, id: starting_after, param: 'starting_after')
          scope = scope.where(Sequel.lit('(created_at, id) < (?, ?)', cursor.created_at, cursor.id))
        end
        rows = scope.order(Sequel.desc(:created_at), Sequel.desc(:id)).limit(limit + 1).all
        [rows.first(limit).map { |r| PaymentIntent.from_row(r) }, rows.length > limit]
      end
    end
  end
end
