# typed: false
# frozen_string_literal: true

# Posts the events of the money-flow table (docs/design/ledger.md) the way the
# domain code will, one Ledger::Flows builder per event.
module MoneyFlowHelpers
  DAY = Clearinghouse::Clock::SECONDS_PER_DAY
  FLOW_TYPES = { 'pi' => 'payment', 're' => 'refund', 'dp' => 'dispute', 'po' => 'payout' }.freeze

  def flows
    Clearinghouse::Ledger::Flows
  end

  # `event` is a Flows method name, `day` the simulated day it happens on.
  def flow_event(flow_id, event, day:, **args)
    Clearinghouse::Ledger.post!(app_db, flow_type: FLOW_TYPES.fetch(flow_id.split('_').first), flow_id: flow_id,
                                        description: event.to_s.tr('_', ' '),
                                        effective_at: LedgerHelpers::T0 + (day * DAY),
                                        entries: flows.public_send(event, **args))
  end
end

RSpec.configure do |config|
  config.include MoneyFlowHelpers, :db
end
