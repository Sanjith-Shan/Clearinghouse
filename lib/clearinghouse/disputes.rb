# typed: true
# frozen_string_literal: true

module Clearinghouse
  # Disputes: opened and closed by the acquirer through its notification feed, or
  # closed by the merchant accepting the loss. See docs/design/disputes.md.
  #
  # This module is the table's repository; Disputes::Service holds the rules.
  module Disputes
    extend T::Sig

    class Error < Clearinghouse::Error; end
    class NotFoundError < Error; end
    # A dispute.opened for an acquirer reference we have no payment for.
    class UnknownPaymentError < Error; end
    # A notification whose data contradicts what we hold (another currency, an
    # outcome that reverses a ruling).
    class InconsistentNotificationError < Error; end
    # The merchant tried to accept a dispute that is already won.
    class AlreadyClosedError < Error; end

    # Where the transactional outbox plugs in. `Events.emit!` (payments work) has this
    # shape; it must write in the caller's database transaction.
    module EventSink
      extend T::Sig
      extend T::Helpers

      interface!

      sig do
        abstract.params(db: Sequel::Database, merchant_id: String, type: String, object: T::Hash[String, T.untyped],
                        clock: Clock).returns(String)
      end
      def emit!(db, merchant_id:, type:, object:, clock:); end
    end

    # Where a crash can land, per mutating flow. The two notification flows run inside
    # the poller's transaction, so their points are the poller's. The merchant's
    # close runs in its own. The crash matrix (spec/settlement/disputes_recovery_spec.rb)
    # iterates this hash.
    RECOVERY_POINTS = T.let({
      'dispute.opened' => Acquirer::NotificationPoller::RECOVERY_POINTS,
      'dispute.closed' => Acquirer::NotificationPoller::RECOVERY_POINTS,
      'dispute.accept' => %w[dispute_locked effects_written committed].freeze
    }.freeze, T::Hash[String, T::Array[String]])

    sig do
      params(db: Sequel::Database, dispute: Dispute, now: Time).void
    end
    def self.insert!(db, dispute, now:)
      db[:disputes].insert(
        id: dispute.id, merchant_id: dispute.merchant_id, payment_intent: dispute.payment_intent,
        amount: dispute.amount.amount, fee: dispute.fee.amount, currency: dispute.amount.currency,
        reason: dispute.reason, status: dispute.status, closed_by: dispute.closed_by,
        acquirer_dispute_id: dispute.acquirer_dispute_id, acquirer_reference: dispute.acquirer_reference,
        opened_transaction_id: dispute.opened_transaction_id, won_transaction_id: dispute.won_transaction_id,
        created_at: dispute.created_at, closed_at: dispute.closed_at, updated_at: now
      )
    end

    # Writes the fields that change when a dispute closes.
    sig { params(db: Sequel::Database, dispute: Dispute, now: Time).void }
    def self.save!(db, dispute, now:)
      updated = db[:disputes].where(id: dispute.id).update(
        status: dispute.status, closed_by: dispute.closed_by, closed_at: dispute.closed_at,
        won_transaction_id: dispute.won_transaction_id, updated_at: now
      )
      raise Error, "dispute #{dispute.id} vanished" unless updated == 1
    end

    sig { params(db: Sequel::Database, merchant_id: String, id: String, lock: T::Boolean).returns(T.nilable(Dispute)) }
    def self.find(db, merchant_id:, id:, lock: false)
      scope = db[:disputes].where(merchant_id: merchant_id, id: id)
      row = (lock ? scope.for_update : scope).first
      row ? Dispute.from_row(row) : nil
    end

    sig { params(db: Sequel::Database, acquirer_dispute_id: String, lock: T::Boolean).returns(T.nilable(Dispute)) }
    def self.by_acquirer_id(db, acquirer_dispute_id, lock: false)
      scope = db[:disputes].where(acquirer_dispute_id: acquirer_dispute_id)
      row = (lock ? scope.for_update : scope).first
      row ? Dispute.from_row(row) : nil
    end

    # Newest first. Returns the page and whether more follow it.
    sig do
      params(db: Sequel::Database, merchant_id: String, limit: Integer, starting_after: T.nilable(String))
        .returns([T::Array[Dispute], T::Boolean])
    end
    def self.list(db, merchant_id:, limit:, starting_after: nil)
      scope = db[:disputes].where(merchant_id: merchant_id)
      if starting_after
        cursor = db[:disputes].where(merchant_id: merchant_id, id: starting_after).first
        raise NotFoundError, "no dispute #{starting_after}" unless cursor

        scope = scope.where(Sequel.lit('(created_at, id) < (?, ?)', cursor.fetch(:created_at), cursor.fetch(:id)))
      end
      rows = scope.order(Sequel.desc(:created_at), Sequel.desc(:id)).limit(limit + 1).all
      [rows.first(limit).map { |row| Dispute.from_row(row) }, rows.length > limit]
    end
  end
end

require_relative 'disputes/dispute'
require_relative 'disputes/fee_policy'
require_relative 'disputes/service'
