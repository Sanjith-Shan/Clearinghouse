# typed: false
# frozen_string_literal: true

require_relative '../../lib/clearinghouse/db'

# Database access for specs tagged :db.
#
# - `app_db` connects as clearinghouse_app, the role the service runs as. Use it for
#   anything that should behave like production, including every negative test of
#   privileges.
# - `owner_db` connects as clearinghouse_owner, which owns the tables. Use it only to
#   prove the triggers hold even for the owner, or to seed damage (drift) that the
#   app role is not allowed to cause.
#
# Every :db example starts from empty tables. Ledger tables reject TRUNCATE by
# trigger, so cleaning runs as the owner with `SET LOCAL session_replication_role =
# replica`, which skips ordinary triggers for that one transaction only. That
# setting needs superuser, which the owner has in dev and CI and the app role never
# does, so the app cannot use the same trick.
#
# Later areas add their tables with `DBHelper.clean_tables(...)` from their own
# support file. Tables that do not exist yet (a branch without that migration) are
# skipped, so the list can run ahead of the schema.
module DBHelper
  @tables = %w[account_balances ledger_entries ledger_transactions ledger_accounts]
  @connections = {}
  @mutex = Mutex.new

  class << self
    attr_reader :tables

    def clean_tables(*names)
      @mutex.synchronize { @tables |= names.map(&:to_s) }
    end

    def app
      connection(:app)
    end

    def owner
      connection(:owner)
    end

    def clean!
      db = owner
      existing = db.fetch("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map(:tablename)
      present = tables & existing
      return if present.empty?

      db.transaction do
        db.run('SET LOCAL session_replication_role = replica')
        db.run("TRUNCATE #{present.map { |t| db.literal(Sequel.identifier(t)) }.join(', ')} RESTART IDENTITY CASCADE")
      end
    end

    def disconnect!
      @mutex.synchronize do
        @connections.each_value(&:disconnect)
        @connections.clear
      end
    end

    private

    def connection(role)
      @mutex.synchronize do
        @connections[role] ||= Clearinghouse::DB.connect(role: role, max_connections: 20)
      end
    end
  end

  def app_db
    DBHelper.app
  end

  def owner_db
    DBHelper.owner
  end
end

RSpec.configure do |config|
  config.include DBHelper, :db
  config.before(:each, :db) { DBHelper.clean! }
  config.after(:suite) { DBHelper.disconnect! }
end
