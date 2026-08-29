# typed: false
# frozen_string_literal: true

# These tests talk to Postgres in raw SQL on purpose. They prove the database
# refuses bad writes on its own, without any help from Clearinghouse::Ledger.
RSpec.describe 'ledger schema', :db do
  def account(db, code, currency = 'usd', kind: 'asset', side: 'D')
    db[:ledger_accounts].insert(code: code, currency: currency, kind: kind, normal_side: side)
  end

  def header(db, flow_id: 'pi_1', flow_type: 'payment', reverses: nil)
    db[:ledger_transactions].insert(flow_id: flow_id, flow_type: flow_type, description: 'raw',
                                    effective_at: Time.utc(2026, 1, 1), reverses_transaction_id: reverses)
  end

  def entry(db, txn, account_id, side, amount, currency: 'usd')
    db[:ledger_entries].insert(transaction_id: txn, account_id: account_id, side: side, amount: amount,
                               currency: currency)
  end

  let(:cash) { account(app_db, 'platform:cash') }
  let(:liability) { account(app_db, 'merchant:m1:pending', kind: 'liability', side: 'C') }

  def balanced_transaction(db = app_db, flow_id: 'pi_1')
    db.transaction do
      txn = header(db, flow_id: flow_id)
      entry(db, txn, cash, 'D', 100)
      entry(db, txn, liability, 'C', 100)
      txn
    end
  end

  def pg_error(error)
    error.wrapped_exception.class
  end

  describe 'double entry, checked at commit' do
    it 'accepts a balanced transaction written in several statements' do
      txn = balanced_transaction
      expect(app_db[:ledger_entries].where(transaction_id: txn).count).to eq(2)
    end

    it 'lets an unbalanced insert through each statement and fails it at COMMIT' do
      cash
      liability
      statements_succeeded = false
      expect do
        app_db.transaction do
          txn = header(app_db)
          entry(app_db, txn, cash, 'D', 100)
          entry(app_db, txn, liability, 'C', 90)
          statements_succeeded = true
        end
      end.to raise_error(Sequel::CheckConstraintViolation, /unbalanced in usd: debits minus credits is 10/)
      expect(statements_succeeded).to be(true)
      expect(app_db[:ledger_transactions].count).to eq(0)
      expect(app_db[:ledger_entries].count).to eq(0)
    end

    it 'balances per currency, not in total' do
      jpy = account(app_db, 'platform:cash', 'jpy')
      expect do
        app_db.transaction do
          txn = header(app_db)
          entry(app_db, txn, cash, 'D', 100)
          entry(app_db, txn, jpy, 'C', 100, currency: 'jpy')
        end
      end.to raise_error(Sequel::CheckConstraintViolation, /unbalanced/)
    end

    it 'accepts a transaction that balances in each of two currencies' do
      jpy_cash = account(app_db, 'platform:cash', 'jpy')
      jpy_pending = account(app_db, 'merchant:m1:pending', 'jpy', kind: 'liability', side: 'C')
      app_db.transaction do
        txn = header(app_db)
        entry(app_db, txn, cash, 'D', 100)
        entry(app_db, txn, liability, 'C', 100)
        entry(app_db, txn, jpy_cash, 'D', 500, currency: 'jpy')
        entry(app_db, txn, jpy_pending, 'C', 500, currency: 'jpy')
      end
      expect(app_db[:ledger_entries].count).to eq(4)
    end

    it 'rejects a transaction with no entries' do
      expect { app_db.transaction { header(app_db) } }
        .to raise_error(Sequel::CheckConstraintViolation, /has 0 entries, needs at least 2/)
    end

    it 'rejects a transaction with a single entry, even one that cannot balance anyway' do
      expect { app_db.transaction { entry(app_db, header(app_db), cash, 'D', 1) } }
        .to raise_error(Sequel::CheckConstraintViolation, /has 1 entries/)
    end

    it 'fails immediately if a session asks for the check to run per statement' do
      cash
      expect do
        app_db.transaction do
          app_db.run('SET CONSTRAINTS ALL IMMEDIATE')
          header(app_db)
        end
      end.to raise_error(Sequel::CheckConstraintViolation, /has 0 entries/)
    end
  end

  describe 'no entries added after the fact' do
    it 'refuses a balanced pair appended to a transaction that already committed' do
      txn = balanced_transaction
      expect do
        app_db.transaction do
          entry(app_db, txn, cash, 'D', 5)
          entry(app_db, txn, liability, 'C', 5)
        end
      end.to raise_error(Sequel::DatabaseError, /must be written in the database transaction that created it/)
    end

    it 'ignores a created_xact supplied by the caller' do
      app_db.transaction do
        txn = app_db[:ledger_transactions].insert(flow_id: 'pi_1', flow_type: 'payment', description: 'x',
                                                  effective_at: Time.utc(2026, 1, 1), created_xact: 1)
        entry(app_db, txn, cash, 'D', 1)
        entry(app_db, txn, liability, 'C', 1)
      end
      expect(app_db[:ledger_transactions].get(:created_xact)).not_to eq(1)
    end
  end

  describe 'append-only' do
    let!(:txn) { balanced_transaction }

    {
      'ledger_entries' => 'UPDATE ledger_entries SET amount = amount + 1',
      'ledger_transactions' => "UPDATE ledger_transactions SET description = 'edited'",
      'ledger_accounts' => "UPDATE ledger_accounts SET code = 'edited'"
    }.each do |table, update|
      context "with #{table}" do
        it 'rejects UPDATE by trigger, even for the owner who holds every privilege' do
          expect { owner_db.run(update) }.to raise_error(Sequel::DatabaseError, /#{table} is append-only: UPDATE/)
        end

        it 'rejects DELETE by trigger for the owner' do
          expect { owner_db.run("DELETE FROM #{table}") }
            .to raise_error(Sequel::DatabaseError, /#{table} is append-only: DELETE/)
        end

        it 'rejects TRUNCATE by trigger for the owner' do
          expect { owner_db.run("TRUNCATE #{table} CASCADE") }
            .to raise_error(Sequel::DatabaseError, /is append-only: TRUNCATE/)
        end

        it 'refuses UPDATE, DELETE and TRUNCATE to the app role by privilege, before any trigger runs' do
          [update, "DELETE FROM #{table}", "TRUNCATE #{table}"].each do |sql|
            expect { app_db.run(sql) }.to raise_error(Sequel::DatabaseError) { |e|
              expect(pg_error(e)).to eq(PG::InsufficientPrivilege)
              expect(e.message).to include("permission denied for table #{table}")
            }
          end
        end
      end
    end

    it 'leaves history untouched after all of that' do
      expect(app_db[:ledger_entries].where(transaction_id: txn).select_map(:amount)).to eq([100, 100])
    end

    it 'grants the app exactly SELECT and INSERT on history, and UPDATE only on balances' do
      privileges = app_db.fetch(<<~SQL).to_hash_groups(:table_name, :privilege_type)
        SELECT table_name, privilege_type FROM information_schema.role_table_grants
        WHERE grantee = 'clearinghouse_app' AND table_name IN
          ('ledger_accounts', 'ledger_transactions', 'ledger_entries', 'account_balances')
      SQL
      expect(privileges.transform_values(&:sort)).to eq(
        'ledger_accounts' => %w[INSERT SELECT],
        'ledger_transactions' => %w[INSERT SELECT],
        'ledger_entries' => %w[INSERT SELECT],
        'account_balances' => %w[INSERT SELECT UPDATE]
      )
    end

    it 'lets the app update a balance row but never delete one' do
      app_db[:account_balances].insert(account_id: cash)
      app_db[:account_balances].where(account_id: cash).update(balance: 5, version: 1)
      expect { app_db[:account_balances].delete }.to raise_error(Sequel::DatabaseError, /permission denied/)
    end
  end

  describe 'column constraints' do
    it 'requires an entry currency to match its account currency' do
      expect do
        app_db.transaction do
          txn = header(app_db)
          entry(app_db, txn, cash, 'D', 100, currency: 'eur')
          entry(app_db, txn, liability, 'C', 100, currency: 'eur')
        end
      end.to raise_error(Sequel::ForeignKeyConstraintViolation)
    end

    it 'rejects zero and negative amounts and unknown sides' do
      [[0, 'D'], [-5, 'C'], [5, 'X']].each do |amount, side|
        expect { app_db.transaction { entry(app_db, header(app_db), cash, side, amount) } }
          .to raise_error(Sequel::CheckConstraintViolation)
      end
    end

    it 'keeps one account per code and currency' do
      cash
      expect { account(app_db, 'platform:cash') }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'keeps every transaction of a flow on one flow_type' do
      balanced_transaction
      expect { app_db.transaction { header(app_db, flow_type: 'refund') } }
        .to raise_error(Sequel::CheckConstraintViolation, /flow pi_1 already has flow_type payment, not refund/)
    end
  end

  describe 'reversals' do
    let!(:original) { balanced_transaction }

    def reversal(db = app_db, target: original, flow_id: 'pi_1', debit: liability, credit: cash, amount: 100)
      db.transaction do
        txn = header(db, flow_id: flow_id, reverses: target)
        entry(db, txn, debit, 'D', amount)
        entry(db, txn, credit, 'C', amount)
        txn
      end
    end

    it 'accepts an exact mirror' do
      expect(reversal).to be > original
    end

    it 'refuses a second reversal of the same transaction' do
      reversal
      expect { reversal }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'refuses to reverse a reversal' do
      first = reversal
      expect { reversal(target: first, debit: cash, credit: liability) }
        .to raise_error(Sequel::CheckConstraintViolation, /is itself a reversal/)
    end

    it 'refuses a reversal that does not mirror the original, at commit' do
      expect { reversal(amount: 60) }
        .to raise_error(Sequel::CheckConstraintViolation, /does not exactly mirror transaction #{original}/)
    end

    it 'refuses a reversal filed under another flow' do
      expect { reversal(flow_id: 'pi_2') }.to raise_error(Sequel::CheckConstraintViolation, /must stay in flow pi_1/)
    end
  end

  it 'cleans between examples even though the tables reject TRUNCATE' do
    balanced_transaction
    DBHelper.clean!
    expect(app_db[:ledger_transactions].count).to eq(0)
    expect(app_db[:ledger_accounts].count).to eq(0)
  end
end
