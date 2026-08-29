# typed: true
# frozen_string_literal: true

require 'sequel'

module Clearinghouse
  # Database connections. Two roles exist on purpose. The owner runs migrations.
  # The app role is what the service connects as, and it has no UPDATE or DELETE
  # on ledger tables, so append-only holds even if the application is wrong.
  module DB
    extend T::Sig

    DEFAULT_HOST = 'localhost:54329'

    sig { params(role: Symbol, database: T.nilable(String), max_connections: Integer).returns(Sequel::Database) }
    def self.connect(role: :app, database: nil, max_connections: 10)
      database ||= ENV.fetch('CLEARINGHOUSE_DB', test_env? ? 'clearinghouse_test' : 'clearinghouse_dev')
      user, password = role == :owner ? %w[clearinghouse_owner owner] : %w[clearinghouse_app app]
      host = ENV.fetch('CLEARINGHOUSE_DB_HOST', DEFAULT_HOST)
      Sequel.connect("postgres://#{user}:#{password}@#{host}/#{database}", max_connections: max_connections,
                                                                           pool_timeout: 30)
    end

    sig { returns(T::Boolean) }
    def self.test_env?
      ENV['CLEARINGHOUSE_ENV'] == 'test' || ENV['RACK_ENV'] == 'test'
    end

    sig { params(database: T.nilable(String)).void }
    def self.migrate!(database: nil)
      Sequel.extension :migration
      db = connect(role: :owner, database: database, max_connections: 1)
      T.unsafe(Sequel::TimestampMigrator).new(db, File.expand_path('../../db/migrations', __dir__)).run
      db.disconnect
    end
  end
end
