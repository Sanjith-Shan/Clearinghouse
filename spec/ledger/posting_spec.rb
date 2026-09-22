# typed: false
# frozen_string_literal: true

# mutant_expression: these examples exercise Ledger::Posting through the module's
# facade, so mutant should run them for Posting's methods and for the facade (it
# matches on names). Without the method names the facade would fall back to every
# ledger spec, property tests included.
RSpec.describe Clearinghouse::Ledger, :db,
               mutant_expression: %w[Clearinghouse::Ledger.post! Clearinghouse::Ledger.reverse!
                                     Clearinghouse::Ledger.balance Clearinghouse::Ledger.balance_for_update
                                     Clearinghouse::Ledger::Posting Clearinghouse::Ledger::UnbalancedError] do
  let(:ledger) { described_class }
  let(:receivable) { 'platform:processor_receivable' }
  let(:fees) { 'platform:fee_revenue' }
  let(:pending) { 'merchant:m1:pending' }
  let(:available) { 'merchant:m1:available' }
  let(:cash) { 'platform:cash' }

  def capture(amount = 10_000, fee = 320, **opts)
    post([debit(receivable, money(amount)), credit(pending, money(amount - fee)), credit(fees, money(fee))], **opts)
  end

  def counts
    %i[ledger_transactions ledger_entries ledger_accounts].map { |t| app_db[t].count }
  end

  describe '.post!' do
    it 'writes the transaction and its entries and returns the id' do
      id = capture(flow_id: 'pi_42', description: 'capture')
      txn = app_db[:ledger_transactions].where(id: id).first
      expect(txn.values_at(:flow_id, :flow_type, :description)).to eq(%w[pi_42 payment capture])
      expect(txn[:effective_at]).to eq(LedgerHelpers::T0)
      rows = app_db[:ledger_entries].join(:ledger_accounts, id: :account_id).where(transaction_id: id)
                                    .order(Sequel[:ledger_entries][:id]).select_map(%i[code side amount])
      expect(rows).to eq([[receivable, 'D', 10_000], [pending, 'C', 9680], [fees, 'C', 320]])
    end

    it 'creates accounts on first use with the kind and normal side their code implies' do
      capture
      accounts = app_db[:ledger_accounts].order(:code).select_map(%i[code currency kind normal_side owner_id])
      expect(accounts).to eq([
                               [pending, 'usd', 'liability', 'C', 'm1'],
                               [fees, 'usd', 'revenue', 'C', nil],
                               [receivable, 'usd', 'clearing', 'D', nil]
                             ])
    end

    it 'reuses accounts and keeps balances signed on each normal side' do
      capture
      capture(5000, 175)
      expect(app_db[:ledger_accounts].count).to eq(3)
      expect(balance_of(receivable)).to eq(15_000)
      expect(balance_of(pending)).to eq(9680 + 4825)
      expect(balance_of(fees)).to eq(495)
      post([debit(pending, money(100)), credit(receivable, money(100))], flow_id: 'pi_1')
      expect(balance_of(receivable)).to eq(14_900)
      expect(balance_of(pending)).to eq(14_405)
      expect(app_db[:account_balances].select_map(:version).sort).to eq([2, 3, 3])
    end

    it 'nets repeated lines on one account into one balance update' do
      post([debit(cash, money(30)), debit(cash, money(70)), credit(available, money(100))])
      expect(balance_of(cash)).to eq(100)
      expect(app_db[:account_balances].select_map(:version)).to all(eq(1))
    end

    it 'keeps each currency in its own accounts, even within one transaction' do
      post([debit(cash, money(500, 'jpy')), credit(available, money(500, 'jpy')),
            debit(cash, money(1234, 'kwd')), credit(available, money(1234, 'kwd'))])
      expect(balance_of(cash, 'jpy')).to eq(500)
      expect(balance_of(cash, 'KWD')).to eq(1234)
      expect(balance_of(cash, 'usd')).to eq(0)
      expect(app_db[:ledger_accounts].select_map(%i[code currency]).sort)
        .to eq([[available, 'jpy'], [available, 'kwd'], [cash, 'jpy'], [cash, 'kwd']])
    end

    describe 'validation, before anything is written' do
      def expect_rejected(entries, error, message = nil, **opts)
        expect { post(entries, **opts) }.to raise_error(error, message)
        expect(counts).to eq([0, 0, 0])
      end

      it 'rejects an imbalance and says which currency and by how much' do
        entries = [debit(cash, money(100)), credit(available, money(90)),
                   debit(cash, money(5, 'jpy')), credit(available, money(7, 'jpy'))]
        expect { post(entries) }.to raise_error(Clearinghouse::Ledger::UnbalancedError) { |e|
          expect(e.imbalances).to eq('usd' => 10, 'jpy' => -2)
          expect(e.message).to eq('unbalanced ledger transaction (jpy: credits exceed debits by 2 JPY; ' \
                                  'usd: debits exceed credits by 0.10 USD)')
        }
        expect(counts).to eq([0, 0, 0])
      end

      it 'rejects a transaction that balances in total but not per currency' do
        expect_rejected([debit(cash, money(100)), credit(available, money(100, 'eur'))],
                        Clearinghouse::Ledger::UnbalancedError, /eur: credits exceed debits by 1.00 EUR; usd: debits/)
      end

      it 'rejects zero and negative amounts' do
        [0, -100].each do |amount|
          expect_rejected([debit(cash, money(amount)), credit(available, money(amount))],
                          Clearinghouse::Ledger::InvalidPostingError, /must be positive, got .* on platform:cash/)
        end
      end

      it 'rejects a side that is neither debit nor credit' do
        odd = Clearinghouse::Ledger::Entry.new(account: cash, side: :sideways, amount: money(1))
        expect_rejected([odd, credit(available, money(1))], Clearinghouse::Ledger::InvalidPostingError, /:sideways/)
      end

      it 'rejects fewer than two entries' do
        expect_rejected([], Clearinghouse::Ledger::InvalidPostingError, /at least 2 entries, got 0/)
        expect_rejected([debit(cash, money(1))], Clearinghouse::Ledger::InvalidPostingError, /got 1/)
      end

      it 'rejects account codes outside the grammar' do
        expect_rejected([debit('platform:bank', money(1)), credit(available, money(1))],
                        Clearinghouse::Ledger::UnknownAccountError, /platform:bank/)
      end

      it 'rejects an empty flow id or flow type' do
        expect_rejected([debit(cash, money(1)), credit(available, money(1))],
                        Clearinghouse::Ledger::InvalidPostingError, /must not be empty/, flow_id: '')
        expect_rejected([debit(cash, money(1)), credit(available, money(1))],
                        Clearinghouse::Ledger::InvalidPostingError, /must not be empty/, flow_type: '')
      end

      it 'rejects a second flow_type for an existing flow' do
        capture
        expect { post([debit(available, money(1)), credit(cash, money(1))], flow_type: 'refund') }
          .to raise_error(Clearinghouse::Ledger::FlowTypeMismatchError, /pi_1 is a payment flow, not refund/)
        expect(counts).to eq([1, 3, 3])
      end
    end

    describe 'transactions' do
      it "joins the caller's transaction and rolls back with it" do
        app_db.transaction do
          capture
          expect(balance_of(receivable)).to eq(10_000)
          raise Sequel::Rollback
        end
        expect(counts).to eq([0, 0, 0])
        expect(app_db[:account_balances].count).to eq(0)
      end

      it 'is atomic with the balance update when the database refuses the write' do
        capture
        owner_db[:account_balances].where(account_id: owner_db[:ledger_accounts].where(code: pending).get(:id)).delete
        expect { capture }.to raise_error(Clearinghouse::Ledger::BalanceStateError, /has no balance row/)
        expect(counts).to eq([1, 3, 3])
        expect(balance_of(receivable)).to eq(10_000)
      end
    end

    it 'does not deadlock when concurrent postings touch the same accounts in opposite orders' do
      accounts = %w[platform:cash merchant:m1:available merchant:m2:available merchant:m3:available]
      post(accounts.each_cons(2).map { |a, b| [debit(a, money(1)), credit(b, money(1))] }.flatten)
      threads = Array.new(6) do |t|
        Thread.new do
          rng = Random.new(t)
          40.times do
            from, to = accounts.sample(2, random: rng)
            lines = [debit(from, money(7)), credit(to, money(7)), debit(to, money(3)), credit(from, money(3))]
            post(lines.shuffle(random: rng))
          end
        end
      end
      threads.each(&:join)
      expect(app_db[:ledger_transactions].count).to eq(241)
      expect(accounts.sum { |a| balance_of(a) * (a == cash ? 1 : -1) }).to eq(0)
    end
  end

  describe '.balance and .balance_for_update' do
    it 'reads zero for an account that has never been posted to, without creating it' do
      expect(ledger.balance(app_db, available, 'usd')).to eq(money(0))
      expect(app_db[:ledger_accounts].count).to eq(0)
    end

    it 'rejects a bad code or currency' do
      expect { ledger.balance(app_db, 'merchant:m1', 'usd') }.to raise_error(Clearinghouse::Ledger::UnknownAccountError)
      expect { ledger.balance(app_db, cash, 'xyz') }.to raise_error(Clearinghouse::Currency::UnknownCurrencyError)
    end

    it 'refuses to lock outside a transaction, where the lock would be released at once' do
      expect { ledger.balance_for_update(app_db, cash, 'usd') }.to raise_error(Clearinghouse::Ledger::Error, /open/)
    end

    it 'creates a missing account so there is a row to lock' do
      app_db.transaction do
        expect(ledger.balance_for_update(app_db, available, 'usd')).to eq(money(0))
        expect(app_db[:account_balances].count).to eq(1)
      end
    end

    it 'holds the row lock until the transaction ends' do
      capture
      locked = Queue.new
      release = Queue.new
      holder = Thread.new do
        app_db.transaction do
          locked << ledger.balance_for_update(app_db, pending, 'usd')
          release.pop
        end
      end
      expect(locked.pop).to eq(money(9680))
      id = app_db[:ledger_accounts].where(code: pending).get(:id)
      expect { app_db.transaction { app_db[:account_balances].where(account_id: id).for_update.nowait.all } }
        .to raise_error(Sequel::DatabaseError, /could not obtain lock/)
      release << true
      holder.join
    end

    it 'fails loudly if the balance row is missing rather than inventing a zero' do
      capture
      owner_db[:account_balances].delete
      expect { app_db.transaction { ledger.balance_for_update(app_db, pending, 'usd') } }
        .to raise_error(Clearinghouse::Ledger::BalanceStateError)
    end
  end

  describe '.reverse!' do
    let!(:original) { capture }

    def reverse(id = original, reason: 'captured twice')
      ledger.reverse!(app_db, id, reason: reason, effective_at: LedgerHelpers::T0 + 60)
    end

    it 'posts the mirror image in the same flow and restores every balance' do
      id = reverse
      txn = app_db[:ledger_transactions].where(id: id).first
      expect(txn.values_at(:flow_id, :flow_type, :reverses_transaction_id)).to eq(['pi_1', 'payment', original])
      expect(txn[:description]).to eq('reversal: captured twice')
      sides = app_db[:ledger_entries].where(transaction_id: id).order(:id).select_map(%i[side amount])
      expect(sides).to eq([['C', 10_000], ['D', 9680], ['D', 320]])
      expect([receivable, pending, fees].map { |a| balance_of(a) }).to eq([0, 0, 0])
    end

    it 'refuses to reverse the same transaction twice' do
      first = reverse
      expect { reverse }.to raise_error(Clearinghouse::Ledger::AlreadyReversedError, /already reversed by #{first}/)
    end

    it 'refuses to reverse a reversal' do
      expect { reverse(reverse) }.to raise_error(Clearinghouse::Ledger::NotReversibleError, /is a reversal/)
    end

    it 'refuses an unknown transaction and an empty reason' do
      expect { reverse(original + 99) }.to raise_error(Clearinghouse::Ledger::TransactionNotFoundError)
      expect { reverse(reason: ' ') }.to raise_error(Clearinghouse::Ledger::InvalidPostingError, /needs a reason/)
    end

    it 'turns a lost race between two reversals into AlreadyReversedError' do
      inserted = Queue.new
      finish = Queue.new
      winner = Thread.new do
        app_db.transaction do
          reverse
          inserted << true
          finish.pop
        end
      end
      inserted.pop
      loser = Thread.new do
        Thread.current.report_on_exception = false # the error is the expected outcome
        reverse
      end
      # Wait until the loser is blocked on the unique index, then let the winner commit.
      waiting = app_db[:pg_stat_activity].where(wait_event_type: 'Lock', usename: 'clearinghouse_app')
      sleep 0.01 until waiting.any?
      finish << true
      winner.join
      expect { loser.value }.to raise_error(Clearinghouse::Ledger::AlreadyReversedError, /concurrently/)
      expect(app_db[:ledger_transactions].exclude(reverses_transaction_id: nil).count).to eq(1)
    end

    it 're-raises unique violations that are not about reversals' do
      posting = Clearinghouse::Ledger::Posting.new(app_db)
      allow(posting).to receive(:post).and_raise(Sequel::UniqueConstraintViolation, 'some_other_key')
      expect { posting.reverse(original, reason: 'x', effective_at: LedgerHelpers::T0) }
        .to raise_error(Sequel::UniqueConstraintViolation, 'some_other_key')
    end
  end
end
