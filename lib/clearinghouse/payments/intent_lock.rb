# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # Which unfinished request owns a PaymentIntent (payment_intents.locked_by).
    #
    # Confirm, capture and cancel each hold the intent from their first phase to
    # their last, across the acquirer call. Row locks cannot do that: they end
    # with each phase's transaction. Without this, a capture and a cancel could
    # both pass their checks, then one capture at the acquirer and the other void,
    # and the second to record would find the intent in a state it cannot leave
    # from, with money moved and unrecorded. The owner is an idempotency key, so
    # if its process dies the completer finishes the request and releases it.
    module IntentLock
      extend T::Sig

      sig { params(db: Sequel::Database, intent_id: String, key_id: Integer).void }
      def self.take!(db, intent_id, key_id)
        taken = db[:payment_intents].where(id: intent_id)
                                    .where(Sequel.lit('locked_by IS NULL OR locked_by = ?', key_id))
                                    .update(locked_by: key_id)
        return if taken == 1

        raise Api::Errors::LockTimeoutError, 'This PaymentIntent is being changed by another request. Retry shortly.'
      end

      sig { params(db: Sequel::Database, intent_id: String, key_id: Integer).void }
      def self.release(db, intent_id, key_id)
        db[:payment_intents].where(id: intent_id, locked_by: key_id).update(locked_by: nil)
      end
    end
  end
end
