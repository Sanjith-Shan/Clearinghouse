# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # Cancels authorizations that waited too long for capture. Card networks let an
    # uncaptured authorization lapse after about a week; the TTL is
    # Dependencies#authorization_ttl_days, and "now" is the injected clock, so a
    # test expires one by advancing its test clock.
    #
    # The sweep sends no void. The authorization lapses at the acquirer on its
    # own, and nothing here can capture a canceled intent, so a void would only
    # add a foreign call that can fail.
    module Expiry
      extend T::Sig

      # Expires every due authorization, oldest first, one transaction each, and
      # returns the ids it canceled.
      sig { params(deps: Api::Dependencies, limit: Integer).returns(T::Array[String]) }
      def self.sweep!(deps, limit: 100)
        now = deps.clock.now
        due = deps.db[:payment_intents].where(status: 'requires_capture')
                  .where(Sequel.lit('authorization_expires_at <= ?', now))
                  .order(:authorization_expires_at).limit(limit).select_map(%i[id merchant_id])
        due.filter_map { |id, merchant_id| expire!(deps, id, merchant_id) }
      end

      # nil when someone else got there first (a capture or cancel that committed
      # between the sweep's read and this lock).
      sig { params(deps: Api::Dependencies, id: String, merchant_id: String).returns(T.nilable(String)) }
      def self.expire!(deps, id, merchant_id)
        merchant = T.must(Merchants.find(deps.db, merchant_id))
        ctx = Api::Context.background(deps, merchant)
        deps.db.transaction do
          intent = PaymentIntents.lock!(deps.db, merchant_id: merchant_id, id: id)
          next nil unless intent.status == StateMachine::Status::RequiresCapture &&
                          T.must(intent.authorization_expires_at) <= deps.clock.now

          Cancel.record!(deps.db, ctx, Cancel::Input.new(intent_id: id, cancellation_reason: nil),
                         event: StateMachine::Event::AuthorizationExpired, reason: 'automatic')
          id
        end
      end
    end
  end
end
