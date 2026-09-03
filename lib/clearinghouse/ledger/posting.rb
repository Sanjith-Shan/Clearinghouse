# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Ledger
    # Writes ledger transactions. Ruby validates everything it can first, so a bad
    # posting fails with a typed error that says what is wrong. The database checks
    # the same rules again at commit, because it is the only layer that sees every
    # writer, including a raw SQL session or a future bug in this file.
    class Posting
      extend T::Sig

      AccountKey = T.type_alias { [String, String] } # [code, currency]

      sig { params(db: Sequel::Database).void }
      def initialize(db)
        @db = db
      end

      sig do
        params(flow_type: String, flow_id: String, description: String, effective_at: Time,
               entries: T::Array[Entry], reverses: T.nilable(Integer)).returns(Integer)
      end
      def post(flow_type:, flow_id:, description:, effective_at:, entries:, reverses: nil)
        raise InvalidPostingError, 'flow_type and flow_id must not be empty' if flow_type.empty? || flow_id.empty?

        accounts = validate!(entries)
        # Joins the caller's transaction if one is open, so a posting commits or
        # rolls back with the state change it belongs to.
        T.let(@db.transaction do
          check_flow_type!(flow_id, flow_type)
          ids = ensure_accounts(accounts)
          txn_id = insert_transaction(flow_type, flow_id, description, effective_at, reverses)
          @db[:ledger_entries].multi_insert(entries.map { |e| entry_row(txn_id, ids, e) })
          apply_balances(entries, accounts, ids)
          txn_id
        end, Integer)
      end

      sig { params(transaction_id: Integer, reason: String, effective_at: Time).returns(Integer) }
      def reverse(transaction_id, reason:, effective_at:)
        raise InvalidPostingError, 'a reversal needs a reason' if reason.strip.empty?

        T.let(@db.transaction do
          original = load_reversible!(transaction_id)
          post(flow_type: original.fetch(:flow_type), flow_id: original.fetch(:flow_id),
               description: "reversal: #{reason}",
               effective_at: effective_at, entries: entries_of(transaction_id).map(&:flipped),
               reverses: transaction_id)
        end, Integer)
      rescue Sequel::UniqueConstraintViolation => e
        # Two reversals raced past the check above. The unique index picked one.
        raise unless e.message.include?('reverses_transaction_id')

        raise AlreadyReversedError, "transaction #{transaction_id} was reversed concurrently"
      end

      sig { params(account: String, currency: String, lock: T::Boolean).returns(Money) }
      def balance(account, currency, lock: false)
        parsed = AccountCode.parse(account)
        currency = Currency.normalize(currency)
        if lock
          raise Error, 'balance_for_update needs an open database transaction' unless @db.in_transaction?

          # Create the account so there is a row to lock; otherwise two first-time
          # readers would both see zero with nothing to serialize them.
          id = ensure_accounts({ [parsed.code, currency] => parsed }).fetch([parsed.code, currency])
          amount = @db[:account_balances].where(account_id: id).for_update.get(:balance)
          raise BalanceStateError, "account #{account} #{currency} has no balance row" if amount.nil?
        else
          amount = @db[:account_balances].join(:ledger_accounts, id: :account_id)
                                         .where(code: parsed.code, currency: currency).get(:balance)
        end
        Money.of(Integer(amount || 0), currency)
      end

      private

      # Everything that can be checked without the database. Returns the parsed
      # account for each (code, currency) the posting touches. An account is a code
      # in one currency, so an entry can never land in an account of another
      # currency; the composite foreign key on ledger_entries holds that for raw SQL.
      sig { params(entries: T::Array[Entry]).returns(T::Hash[AccountKey, AccountCode]) }
      def validate!(entries)
        count = entries.length
        raise InvalidPostingError, "a ledger transaction needs at least 2 entries, got #{count}" if count < 2

        accounts = T.let({}, T::Hash[AccountKey, AccountCode])
        nets = T.let({}, T::Hash[String, Integer])
        entries.each do |entry|
          validate_entry!(entry)
          accounts[[entry.account, entry.amount.currency]] ||= AccountCode.parse(entry.account)
          nets[entry.amount.currency] = nets.fetch(entry.amount.currency, 0) + entry.signed_amount
        end
        imbalances = nets.reject { |_, net| net.zero? }
        raise UnbalancedError, imbalances unless imbalances.empty?

        accounts
      end

      sig { params(entry: Entry).void }
      def validate_entry!(entry)
        raise InvalidPostingError, "side must be :debit or :credit, got #{entry.side.inspect}" unless
          Entry::SIDES.include?(entry.side)
        return if entry.amount.positive?

        raise InvalidPostingError, "entry amounts must be positive, got #{entry.amount} on #{entry.account}"
      end

      sig { params(flow_id: String, flow_type: String).void }
      def check_flow_type!(flow_id, flow_type)
        existing = @db[:ledger_transactions].where(flow_id: flow_id).exclude(flow_type: flow_type).get(:flow_type)
        return if existing.nil?

        raise FlowTypeMismatchError, "flow #{flow_id} is a #{existing} flow, not #{flow_type}"
      end

      # Finds or creates each account, in sorted order so concurrent first posts to
      # the same new accounts wait on each other in one order and cannot deadlock.
      sig { params(accounts: T::Hash[AccountKey, AccountCode]).returns(T::Hash[AccountKey, Integer]) }
      def ensure_accounts(accounts)
        ids = lookup_accounts(accounts.keys)
        accounts.keys.sort.each do |key|
          next if ids.key?(key)

          parsed = accounts.fetch(key)
          inserted = @db.fetch(<<~SQL, key[0], key[1], parsed.kind.to_s, parsed.normal_side_column, parsed.owner_id).all
            INSERT INTO ledger_accounts (code, currency, kind, normal_side, owner_id)
            VALUES (?, ?, ?, ?, ?) ON CONFLICT (code, currency) DO NOTHING RETURNING id
          SQL
          # Nothing returned means another session created it first.
          id = inserted.empty? ? lookup_accounts([key]).fetch(key) : inserted.fetch(0).fetch(:id)
          @db.run(Sequel.lit('INSERT INTO account_balances (account_id) VALUES (?) ON CONFLICT DO NOTHING', id))
          ids[key] = Integer(id)
        end
        ids
      end

      sig { params(keys: T::Array[AccountKey]).returns(T::Hash[AccountKey, Integer]) }
      def lookup_accounts(keys)
        found = T.let({}, T::Hash[AccountKey, Integer])
        @db[:ledger_accounts].where(%i[code currency] => keys).select(:id, :code, :currency).each do |row|
          found[[row.fetch(:code), row.fetch(:currency)]] = Integer(row.fetch(:id))
        end
        found
      end

      sig do
        params(flow_type: String, flow_id: String, description: String, effective_at: Time,
               reverses: T.nilable(Integer)).returns(Integer)
      end
      def insert_transaction(flow_type, flow_id, description, effective_at, reverses)
        Integer(@db[:ledger_transactions].insert(flow_type: flow_type, flow_id: flow_id, description: description,
                                                 effective_at: effective_at, reverses_transaction_id: reverses))
      end

      sig { params(txn_id: Integer, ids: T::Hash[AccountKey, Integer], entry: Entry).returns(T::Hash[Symbol, T.untyped]) }
      def entry_row(txn_id, ids, entry)
        { transaction_id: txn_id, account_id: ids.fetch([entry.account, entry.amount.currency]),
          side: entry.side_column, amount: entry.amount.amount, currency: entry.amount.currency }
      end

      # Balances are signed on each account's normal side, so a merchant's available
      # balance reads as a positive number when we owe them money. Rows are updated
      # in ascending account id order: two postings that share accounts take their
      # row locks in the same order, so neither can hold one lock while waiting on
      # the other's.
      sig do
        params(entries: T::Array[Entry], accounts: T::Hash[AccountKey, AccountCode],
               ids: T::Hash[AccountKey, Integer]).void
      end
      def apply_balances(entries, accounts, ids)
        deltas = T.let({}, T::Hash[Integer, Integer])
        entries.each do |entry|
          key = [entry.account, entry.amount.currency]
          id = ids.fetch(key)
          normal = accounts.fetch(key).normal_side == entry.side
          deltas[id] = deltas.fetch(id, 0) + (normal ? entry.amount.amount : -entry.amount.amount)
        end
        deltas.sort.each do |account_id, delta|
          updated = @db[:account_balances].where(account_id: account_id)
                                          .update(balance: Sequel[:balance] + delta, version: Sequel[:version] + 1)
          raise BalanceStateError, "account #{account_id} has no balance row" unless updated == 1
        end
      end

      sig { params(transaction_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def load_reversible!(transaction_id)
        original = @db[:ledger_transactions].where(id: transaction_id).first
        raise TransactionNotFoundError, "no ledger transaction #{transaction_id}" if original.nil?
        if original[:reverses_transaction_id]
          raise NotReversibleError, "transaction #{transaction_id} is a reversal; post a new transaction instead"
        end

        existing = @db[:ledger_transactions].where(reverses_transaction_id: transaction_id).get(:id)
        raise AlreadyReversedError, "transaction #{transaction_id} was already reversed by #{existing}" if existing

        original
      end

      sig { params(transaction_id: Integer).returns(T::Array[Entry]) }
      def entries_of(transaction_id)
        @db[:ledger_entries].join(:ledger_accounts, id: :account_id)
                            .where(transaction_id: transaction_id).order(Sequel[:ledger_entries][:id])
                            .select(Sequel[:ledger_accounts][:code], :side, :amount, Sequel[:ledger_entries][:currency])
                            .map do |row|
          Entry.new(account: row.fetch(:code), side: Entry.side_from_column(row.fetch(:side)),
                    amount: Money.of(Integer(row.fetch(:amount)), row.fetch(:currency)))
        end
      end
    end
  end
end
