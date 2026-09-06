# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Payments::StateMachine do
  let(:status) { described_class::Status }
  let(:event) { described_class::Event }

  describe 'the table' do
    it 'is deterministic: for any capture method at most one row applies to a (from, event)' do
      %w[automatic manual].each do |capture_method|
        described_class::TABLE.group_by { |t| [t.from, t.event] }.each do |(from, ev), rows|
          applicable = rows.select { |t| t.guard.nil? || t.guard.holds?(capture_method) }
          expect(applicable.length).to eq(1), "#{from.serialize} + #{ev.serialize} (#{capture_method})"
        end
      end
    end

    it 'reaches every status from the initial ones' do
      reached = [status::RequiresPaymentMethod, status::RequiresConfirmation]
      loop do
        more = described_class::TABLE.select { |t| reached.include?(t.from) }.map(&:to).uniq - reached
        break if more.empty?

        reached += more
      end
      expect(reached).to match_array(status.values)
    end

    it 'has no way out of canceled, and only refunds out of succeeded' do
      expect(described_class::TABLE.select { |t| t.from == status::Canceled }).to be_empty
      expect(described_class::TABLE.select { |t| t.from == status::Succeeded }.map(&:to)).to eq([status::Succeeded])
    end

    it 'starts an intent with a payment method at requires_confirmation, without one at requires_payment_method' do
      expect(described_class.initial(payment_method: 'pm_card_visa')).to eq(status::RequiresConfirmation)
      expect(described_class.initial(payment_method: nil)).to eq(status::RequiresPaymentMethod)
    end
  end

  describe 'legal transitions' do
    described_class::TABLE.each do |row|
      methods = row.guard ? [row.guard.serialize.sub('_capture', '')] : %w[automatic manual]
      methods.each do |capture_method|
        it "#{row.from.serialize} + #{row.event.serialize} (#{capture_method}) -> #{row.to.serialize}" do
          expect(described_class.transition(row.from, row.event, capture_method: capture_method)).to eq(row.to)
        end
      end
    end

    it 'sends an automatic approval to succeeded and a manual one to requires_capture' do
      approved = event::AuthorizationApproved
      expect(described_class.transition(status::Processing, approved, capture_method: 'automatic'))
        .to eq(status::Succeeded)
      expect(described_class.transition(status::Processing, approved, capture_method: 'manual'))
        .to eq(status::RequiresCapture)
    end
  end

  # Generated from the table: every (status, event) pair the table does not list.
  describe 'illegal transitions' do
    described_class.illegal_pairs.each do |from, ev|
      it "refuses #{ev.serialize} from #{from.serialize}" do
        expect { described_class.transition(from, ev, capture_method: 'automatic') }
          .to raise_error(described_class::UnexpectedStateError) { |e|
            expect([e.status, e.event]).to eq([from, ev])
            expect(e.message).to include("status #{from.serialize}").or include("status of #{from.serialize}")
          }
      end
    end

    it 'covers every pair the table leaves out, and nothing it lists' do
      pairs = described_class.illegal_pairs
      expect(pairs.length + described_class::TABLE.map { |t| [t.from, t.event] }.uniq.length)
        .to eq(status.values.length * event.values.length)
      expect(pairs).to include([status::Processing, event::Cancel], [status::Succeeded, event::Capture],
                               [status::Canceled, event::Confirm], [status::RequiresCapture, event::Refund])
    end

    it 'says which statuses would have worked, in the words of the request' do
      expect { described_class.transition(status::Succeeded, event::Capture, capture_method: 'manual') }
        .to raise_error(described_class::UnexpectedStateError,
                        'You cannot capture this PaymentIntent because it has a status of succeeded. Only a ' \
                        'PaymentIntent with one of the following statuses may be captured: requires_capture.')
    end

    it 'describes internal events for the log' do
      expect(described_class.message(status::Succeeded, event::AuthorizationDeclined))
        .to eq('A PaymentIntent with status succeeded cannot record authorization_declined.')
    end
  end
end
