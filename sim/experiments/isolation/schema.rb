# typed: true
# frozen_string_literal: true

module Experiments
  module Isolation
    # The experiment's own scratch tables: the shape of a payment, a merchant
    # balance and a log of movements, and nothing else.
    #
    # There are deliberately no CHECK constraints (no amount_refunded <=
    # amount_received, no version checks). The point is to measure what each
    # isolation strategy guarantees on its own. Production has those constraints
    # as well (db/migrations/20260924100200_refunds.rb), as defence in depth; here
    # they would turn anomalies into errors and hide them.
    module Schema
      extend T::Sig

      TABLES = %i[iso_movements iso_payments iso_balances].freeze

      sig { params(db: Sequel::Database).void }
      def self.create!(db)
        db.run(<<~SQL)
          CREATE TABLE IF NOT EXISTS iso_payments (
            id integer PRIMARY KEY,
            amount_received bigint NOT NULL,
            amount_refunded bigint NOT NULL DEFAULT 0,
            version bigint NOT NULL DEFAULT 0
          );
          CREATE TABLE IF NOT EXISTS iso_balances (
            id integer PRIMARY KEY,
            opening bigint NOT NULL,
            available bigint NOT NULL,
            version bigint NOT NULL DEFAULT 0
          );
          CREATE TABLE IF NOT EXISTS iso_movements (
            id bigserial PRIMARY KEY,
            kind text NOT NULL,
            amount bigint NOT NULL,
            payment_id integer,
            payment_version_read bigint,
            balance_version_read bigint NOT NULL
          );
        SQL
      end

      # Empty tables, `payments` payments of `captured` each, and one balance.
      sig { params(db: Sequel::Database, payments: Integer, captured: Integer, available: Integer).void }
      def self.reset!(db, payments:, captured:, available:)
        create!(db)
        db.run("TRUNCATE #{TABLES.join(', ')} RESTART IDENTITY")
        db[:iso_payments].import(%i[id amount_received], (1..payments).map { |id| [id, captured] })
        db[:iso_balances].insert(id: Operations::MERCHANT, opening: available, available: available)
      end
    end

    # Anomalies, counted from the data after a run, never from what the
    # operations believed they did.
    module Audit
      extend T::Sig

      # over_refunds          payments whose logged refunds add up to more than was captured
      # over_refunded_cents   by how much, in total
      # lost_updates          writes that another write overwrote: each committed write bumps
      #                       its row's version by one from the version it read, so on each row
      #                       (committed writes) - (versions the row moved) is how many were lost
      # payout_double_spends  payouts computed from the same balance version as a committed
      #                       dispute: the payout paid out money the dispute had also taken
      # balance_drift_cents   final available - (opening + every logged movement); 0 when
      #                       nothing was lost
      sig { params(db: Sequel::Database).returns(T::Hash[String, Integer]) }
      def self.run(db)
        over = db.fetch(<<~SQL).first || {}
          SELECT count(*) AS n, coalesce(sum(excess), 0) AS cents FROM (
            SELECT sum(m.amount) - p.amount_received AS excess
            FROM iso_payments p JOIN iso_movements m ON m.payment_id = p.id AND m.kind = 'refund'
            GROUP BY p.id, p.amount_received HAVING sum(m.amount) > p.amount_received
          ) over_refunded
        SQL
        {
          'over_refunds' => Integer(over.fetch(:n)),
          'over_refunded_cents' => Integer(over.fetch(:cents)),
          'lost_updates' => lost_payment_updates(db) + lost_balance_updates(db),
          'payout_double_spends' => payout_double_spends(db),
          'balance_drift_cents' => balance_drift(db)
        }
      end

      sig { params(db: Sequel::Database).returns(Integer) }
      def self.lost_payment_updates(db)
        Integer(db.get(Sequel.lit(<<~SQL)))
          coalesce((SELECT sum(writes - p.version) FROM iso_payments p
                    JOIN (SELECT payment_id, count(*) AS writes FROM iso_movements
                          WHERE kind = 'refund' GROUP BY payment_id) w ON w.payment_id = p.id), 0)
        SQL
      end

      sig { params(db: Sequel::Database).returns(Integer) }
      def self.lost_balance_updates(db)
        Integer(db.get(Sequel.lit(<<~SQL)))
          (SELECT count(*) FROM iso_movements) - (SELECT version FROM iso_balances)
        SQL
      end

      sig { params(db: Sequel::Database).returns(Integer) }
      def self.payout_double_spends(db)
        Integer(db.get(Sequel.lit(<<~SQL)))
          (SELECT count(DISTINCT p.id) FROM iso_movements p
           JOIN iso_movements d ON d.balance_version_read = p.balance_version_read AND d.kind = 'dispute'
           WHERE p.kind = 'payout')
        SQL
      end

      sig { params(db: Sequel::Database).returns(Integer) }
      def self.balance_drift(db)
        Integer(db.get(Sequel.lit(<<~SQL)))
          (SELECT available - opening FROM iso_balances) -
          (SELECT coalesce(sum(CASE kind WHEN 'credit' THEN amount ELSE -amount END), 0) FROM iso_movements)
        SQL
      end
    end
  end
end
