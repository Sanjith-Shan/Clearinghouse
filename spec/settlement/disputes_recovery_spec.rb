# typed: false
# frozen_string_literal: true

# The crash matrix for dispute handling: every recovery point of every dispute flow,
# enumerated from Disputes::RECOVERY_POINTS so a new point cannot be left out. A crash
# is the hook raising, which aborts the open database transaction exactly as a dead
# process would. After the restart the flow must be complete with each effect once:
# one dispute row, one ledger posting per step, one event per state change, and a
# ledger whose invariants hold.
RSpec.describe Clearinghouse::Disputes, :db do
  include SettlementHelpers
  include DisputeHelpers

  let(:day) { SettlementHelpers::DAY }

  def postings(dispute)
    app_db[:ledger_transactions].where(flow_id: dispute.id).count
  end

  def expect_consistent
    expect(Clearinghouse::Ledger::Invariants.check(app_db)).to be_empty
    expect(app_db[:disputes].count).to eq(1)
  end

  it 'covers every flow' do
    expect(Clearinghouse::Disputes::RECOVERY_POINTS.keys).to eq(%w[dispute.opened dispute.closed dispute.accept])
  end

  Clearinghouse::Disputes::RECOVERY_POINTS.fetch('dispute.opened').each do |point|
    it "dispute.opened recovers from a crash at #{point}" do
      captured_payment
      clock.advance(7 * day)
      expect { poller(hook: crash_once_at(point)).poll }.to raise_error(SettlementHelpers::SimulatedCrash)
      poller.poll

      expect_consistent
      expect(postings(the_dispute)).to eq(1)
      expect(events.types).to eq(['charge.dispute.created'])
      expect(available).to eq(9_680 - 10_000 - 1_500)
    end
  end

  Clearinghouse::Disputes::RECOVERY_POINTS.fetch('dispute.closed').each do |point|
    it "dispute.closed (won) recovers from a crash at #{point}" do
      captured_payment
      clock.advance(7 * day)
      poller.poll
      resolve_at_acquirer('won')
      expect { poller(hook: crash_once_at(point)).poll }.to raise_error(SettlementHelpers::SimulatedCrash)
      poller.poll

      expect_consistent
      expect(the_dispute.status).to eq('won')
      expect(postings(the_dispute)).to eq(2)
      expect(events.types).to eq(%w[charge.dispute.created charge.dispute.closed])
      expect(available).to eq(9_680 - 1_500)
    end
  end

  Clearinghouse::Disputes::RECOVERY_POINTS.fetch('dispute.accept').each do |point|
    it "the merchant's accept recovers from a crash at #{point} when the client retries" do
      captured_payment
      clock.advance(7 * day)
      poller.poll
      id = the_dispute.id
      crashing = Clearinghouse::Disputes::Service.new(lookup: lookup, events: events, clock: clock,
                                                      crash_hook: crash_once_at(point))
      expect { crashing.accept(app_db, merchant_id: merchant.id, id: id) }
        .to raise_error(SettlementHelpers::SimulatedCrash)
      retried = service.accept(app_db, merchant_id: merchant.id, id: id)

      expect_consistent
      expect(retried).to have_attributes(status: 'lost', closed_by: 'merchant')
      expect(postings(retried)).to eq(1)
      expect(events.types).to eq(%w[charge.dispute.created charge.dispute.closed])
    end
  end
end
