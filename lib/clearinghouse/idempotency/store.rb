# typed: strict
# frozen_string_literal: true

require 'json'

module Clearinghouse
  module Idempotency
    # Another runner holds the key's lease, or took it over after ours expired.
    # Raised by a phase's commit, so that phase's work rolls back with it.
    class LockLostError < Clearinghouse::Error; end

    # One idempotency_keys row.
    class Record < T::Struct
      extend T::Sig

      const :id, Integer
      const :merchant_id, String
      const :key, String
      const :client_supplied, T::Boolean
      const :flow, String
      const :flow_input, T::Hash[String, T.untyped]
      const :flow_state, T::Hash[String, T.untyped]
      const :request_method, String
      const :request_path, String
      const :request_fingerprint, String
      const :request_id, String
      const :render_options, T::Hash[String, T.untyped]
      const :recovery_point, String
      const :locked_at, T.nilable(Time)
      const :lock_token, T.nilable(String)
      const :last_run_at, Time
      const :response, T.nilable(Response)
      const :created_at, Time

      sig { returns(T::Boolean) }
      def finished?
        recovery_point == FINISHED
      end

      # Held by a runner whose lease has not run out.
      sig { params(now: Time, lock_timeout: Numeric).returns(T::Boolean) }
      def locked?(now, lock_timeout)
        at = locked_at
        !at.nil? && at > now - lock_timeout
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(Record) }
      def self.from_row(row)
        new(
          id: row.fetch(:id), merchant_id: row.fetch(:merchant_id), key: row.fetch(:key),
          client_supplied: row.fetch(:client_supplied), flow: row.fetch(:flow),
          flow_input: parse(row.fetch(:flow_input)), flow_state: parse(row.fetch(:flow_state)),
          request_method: row.fetch(:request_method), request_path: row.fetch(:request_path),
          request_fingerprint: row.fetch(:request_fingerprint), request_id: row.fetch(:request_id),
          render_options: parse(row.fetch(:render_options)), recovery_point: row.fetch(:recovery_point),
          locked_at: row[:locked_at]&.utc, lock_token: row[:lock_token], last_run_at: row.fetch(:last_run_at).utc,
          response: response_from(row), created_at: row.fetch(:created_at).utc
        )
      end

      sig { params(row: T::Hash[Symbol, T.untyped]).returns(T.nilable(Response)) }
      def self.response_from(row)
        code = row[:response_code]
        return nil if code.nil?

        headers = parse(row.fetch(:response_headers)).transform_values(&:to_s)
        Response.new(status: code, body: row.fetch(:response_body), headers: headers)
      end

      # json columns come back as text (the pg_json extension is not loaded).
      sig { params(value: T.untyped).returns(T::Hash[String, T.untyped]) }
      def self.parse(value)
        JSON.parse(String(value))
      end
    end

    # Reads and writes idempotency_keys. Every write that belongs to a runner is
    # conditional on its lease token and, for phase commits, on the recovery
    # point it expects to move from, so a stale runner changes nothing.
    module Store
      extend T::Sig

      TABLE = :idempotency_keys

      sig { params(db: Sequel::Database, merchant_id: String, key: String).returns(T.nilable(Record)) }
      def self.find_for_update(db, merchant_id, key)
        row = db[TABLE].where(merchant_id: merchant_id, key: key).for_update.first
        row ? Record.from_row(row) : nil
      end

      sig { params(db: Sequel::Database, attributes: T::Hash[Symbol, T.untyped]).returns(Record) }
      def self.insert(db, attributes)
        row = attributes.merge(
          flow_input: json(attributes.fetch(:flow_input)), flow_state: json({}),
          render_options: json(attributes.fetch(:render_options))
        )
        id = db[TABLE].insert(row)
        Record.from_row(db[TABLE].where(id: id).first)
      end

      # Takes the lease: a new token and a fresh locked_at.
      sig { params(db: Sequel::Database, record: Record, token: String, now: Time).returns(Record) }
      def self.lease(db, record, token, now)
        db[TABLE].where(id: record.id).update(locked_at: now, lock_token: token, last_run_at: now)
        Record.from_row(db[TABLE].where(id: record.id).first)
      end

      # A phase's commit: moves the recovery point and renews the lease, or
      # raises LockLostError (rolling the phase back) if the key is no longer ours
      # at the point we think it is.
      sig do
        params(db: Sequel::Database, id: Integer, token: String, from: String, to: String,
               state: T::Hash[String, T.untyped], now: Time).void
      end
      def self.advance!(db, id, token, from:, to:, state:, now:)
        count = db[TABLE].where(id: id, lock_token: token, recovery_point: from)
                         .update(recovery_point: to, flow_state: json(state), locked_at: now, last_run_at: now)
        raise LockLostError, "key #{id} is no longer held at #{from}" unless count == 1
      end

      sig do
        params(db: Sequel::Database, id: Integer, token: String, from: String, response: Response,
               state: T::Hash[String, T.untyped], now: Time).void
      end
      def self.finish!(db, id, token, from:, response:, state:, now:)
        count = db[TABLE].where(id: id, lock_token: token, recovery_point: from)
                         .update(recovery_point: FINISHED, flow_state: json(state), locked_at: nil, lock_token: nil,
                                 last_run_at: now, response_code: response.status, response_body: response.body,
                                 response_headers: json(response.headers))
        raise LockLostError, "key #{id} is no longer held at #{from}" unless count == 1
      end

      # Gives the lease back so a retry need not wait for it to expire. A no-op if
      # someone else holds it now.
      sig { params(db: Sequel::Database, id: Integer, token: String).void }
      def self.release(db, id, token)
        db[TABLE].where(id: id, lock_token: token).update(locked_at: nil, lock_token: nil)
      end

      sig { params(db: Sequel::Database, id: Integer).void }
      def self.delete(db, id)
        db[TABLE].where(id: id).delete
      end

      sig { params(value: T.untyped).returns(Sequel::SQL::Cast) }
      def self.json(value)
        Sequel.cast(JSON.generate(value), :json)
      end
      private_class_method :json
    end
  end
end
