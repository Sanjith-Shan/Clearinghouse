# typed: false
# frozen_string_literal: true

# Small builders for ledger specs, so a test reads like the money-flow table.
module LedgerHelpers
  T0 = Time.utc(2026, 1, 1)

  def money(amount, currency = 'usd')
    Clearinghouse::Money.of(amount, currency)
  end

  def debit(code, amount)
    Clearinghouse::Ledger::Entry.debit(code, amount)
  end

  def credit(code, amount)
    Clearinghouse::Ledger::Entry.credit(code, amount)
  end

  def post(entries, db: app_db, flow_id: 'pi_1', flow_type: 'payment', at: T0, description: 'test')
    Clearinghouse::Ledger.post!(db, flow_type: flow_type, flow_id: flow_id, description: description,
                                    effective_at: at, entries: entries)
  end

  def balance_of(code, currency = 'usd', db: app_db)
    Clearinghouse::Ledger.balance(db, code, currency).amount
  end
end

RSpec.configure do |config|
  config.include LedgerHelpers, :db
end
