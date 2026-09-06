# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Payments
    # The PaymentIntent state machine, as data. TABLE is the whole machine: every
    # legal (from, event) pair, the state it leads to, and the guard that picks
    # between two rows with the same (from, event). Nothing else in the code
    # decides whether a status change is allowed; services ask `transition` and
    # get the new status or a typed error. The illegal-transition tests are
    # generated from this table, so a row added here is tested automatically.
    #
    #   requires_payment_method -> requires_confirmation -> processing -> requires_capture -> succeeded
    #             |                         |                   |               |
    #             +----------> canceled <---+                   |               +--> canceled (void, or expiry)
    #                                                           +-> requires_payment_method (decline)
    #                                                           +-> succeeded (automatic capture)
    #
    # `processing` cannot be canceled. It means an authorization is in flight
    # whose outcome may still be unknown (an acquirer timeout), and a cancel then
    # would race the confirm that owns it. Stripe refuses it too. The confirm
    # finishes (or the completer finishes it), and the intent can be canceled from
    # wherever it lands.
    module StateMachine
      extend T::Sig

      # The statuses Stripe's PaymentIntent has, minus the ones for flows
      # Clearinghouse does not simulate (requires_action for 3-D Secure).
      class Status < T::Enum
        enums do
          RequiresPaymentMethod = new('requires_payment_method')
          RequiresConfirmation = new('requires_confirmation')
          Processing = new('processing')
          RequiresCapture = new('requires_capture')
          Succeeded = new('succeeded')
          Canceled = new('canceled')
        end
      end

      # What can happen to an intent. The first four are requests a merchant makes;
      # the rest are outcomes Clearinghouse records.
      class Event < T::Enum
        enums do
          Confirm = new('confirm')
          Capture = new('capture')
          Cancel = new('cancel')
          Refund = new('refund')
          AuthorizationApproved = new('authorization_approved')
          AuthorizationDeclined = new('authorization_declined')
          AuthorizationExpired = new('authorization_expired')
        end
      end

      # Picks between rows that share (from, event). Only the approval needs one:
      # automatic capture goes straight to succeeded.
      class Guard < T::Enum
        enums do
          ManualCapture = new('manual_capture')
          AutomaticCapture = new('automatic_capture')
        end

        extend T::Sig

        sig { params(capture_method: String).returns(T::Boolean) }
        def holds?(capture_method)
          case self
          when ManualCapture then capture_method == 'manual'
          when AutomaticCapture then capture_method == 'automatic'
          else T.absurd(self)
          end
        end
      end

      # One row of the table.
      class Transition < T::Struct
        const :from, Status
        const :event, Event
        const :to, Status
        const :guard, T.nilable(Guard), default: nil
      end

      S = Status
      E = Event

      TABLE = T.let([
        Transition.new(from: S::RequiresPaymentMethod, event: E::Confirm, to: S::Processing),
        Transition.new(from: S::RequiresConfirmation, event: E::Confirm, to: S::Processing),
        Transition.new(from: S::Processing, event: E::AuthorizationApproved, to: S::RequiresCapture,
                       guard: Guard::ManualCapture),
        Transition.new(from: S::Processing, event: E::AuthorizationApproved, to: S::Succeeded,
                       guard: Guard::AutomaticCapture),
        Transition.new(from: S::Processing, event: E::AuthorizationDeclined, to: S::RequiresPaymentMethod),
        # A partial capture is still this row: the rest of the authorization is released.
        Transition.new(from: S::RequiresCapture, event: E::Capture, to: S::Succeeded),
        Transition.new(from: S::RequiresPaymentMethod, event: E::Cancel, to: S::Canceled),
        Transition.new(from: S::RequiresConfirmation, event: E::Cancel, to: S::Canceled),
        Transition.new(from: S::RequiresCapture, event: E::Cancel, to: S::Canceled),
        Transition.new(from: S::RequiresCapture, event: E::AuthorizationExpired, to: S::Canceled),
        # A refund does not change the intent's status; it is here so that "refund an
        # intent that has not succeeded" is an illegal transition like any other.
        Transition.new(from: S::Succeeded, event: E::Refund, to: S::Succeeded)
      ].freeze, T::Array[Transition])

      # The events a merchant's request can cause, with the verb its error message
      # uses.
      REQUEST_EVENTS = T.let({
        E::Confirm => %w[confirm confirmed],
        E::Capture => %w[capture captured],
        E::Cancel => %w[cancel canceled],
        E::Refund => %w[refund refunded]
      }.freeze, T::Hash[Event, [String, String]])

      # The status an intent is in when it is not allowed to take an event.
      class UnexpectedStateError < Clearinghouse::Error
        extend T::Sig

        sig { returns(Status) }
        attr_reader :status

        sig { returns(Event) }
        attr_reader :event

        sig { params(status: Status, event: Event, message: String).void }
        def initialize(status, event, message)
          super(message)
          @status = status
          @event = event
        end
      end

      # The status after `event`, or UnexpectedStateError. Raises before anything is
      # written, so a refused request leaves no trace.
      sig { params(from: Status, event: Event, capture_method: String).returns(Status) }
      def self.transition(from, event, capture_method:)
        row = TABLE.find do |t|
          t.from == from && t.event == event && (t.guard.nil? || T.must(t.guard).holds?(capture_method))
        end
        return row.to if row

        raise UnexpectedStateError.new(from, event, message(from, event))
      end

      sig { params(from: Status, event: Event).returns(T::Boolean) }
      def self.allowed?(from, event)
        TABLE.any? { |t| t.from == from && t.event == event }
      end

      # Statuses an event is legal from, in table order.
      sig { params(event: Event).returns(T::Array[Status]) }
      def self.sources(event)
        TABLE.select { |t| t.event == event }.map(&:from).uniq
      end

      # Every (from, event) pair that is not in the table. The illegal-transition
      # tests iterate over this.
      sig { returns(T::Array[[Status, Event]]) }
      def self.illegal_pairs
        Status.values.product(Event.values).reject { |from, event| allowed?(from, event) }
      end

      # A new intent needs a payment method before it can be confirmed.
      sig { params(payment_method: T.nilable(String)).returns(Status) }
      def self.initial(payment_method:)
        payment_method ? S::RequiresConfirmation : S::RequiresPaymentMethod
      end

      # Stripe's wording: says what was refused, why, and which statuses would have
      # worked, which is what a developer reading the error needs.
      sig { params(from: Status, event: Event).returns(String) }
      def self.message(from, event)
        words = REQUEST_EVENTS[event]
        # Internal events never reach a merchant unless something is broken; the
        # message is for the log.
        return "A PaymentIntent with status #{from.serialize} cannot record #{event.serialize}." if words.nil?

        verb, past = words
        allowed = sources(event).map(&:serialize).join(', ')
        "You cannot #{verb} this PaymentIntent because it has a status of #{from.serialize}. " \
          "Only a PaymentIntent with one of the following statuses may be #{past}: #{allowed}."
      end
    end
  end
end
