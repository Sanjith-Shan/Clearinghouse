# typed: false
# frozen_string_literal: true

# Merchants and their secret keys. Keys are stored only as a SHA-256 hex digest;
# the plaintext is returned once, at creation. The app role may create and read
# merchants and nothing else: nothing in the API edits or deletes one yet.
Sequel.migration do
  up do
    create_table(:merchants) do
      String :id, primary_key: true
      String :name, null: false
      String :secret_key_hash, null: false, unique: true
      String :secret_key_last4, null: false
      String :api_version, null: false
      Integer :fee_rate_scaled, null: false, default: 290_000
      column :fee_fixed_minor, :jsonb, null: false, default: Sequel.lit(%q('{"usd": 30}'::jsonb))
      String :payout_interval, null: false, default: 'daily'
      Integer :payout_delay_days, null: false, default: 2
      column :created_at, :timestamptz, null: false

      constraint(:merchants_id_format, Sequel.lit("id ~ '^acct_[A-Za-z0-9]{24}$'"))
      constraint(:merchants_key_hash_format, Sequel.lit("secret_key_hash ~ '^[0-9a-f]{64}$'"))
      constraint(:merchants_api_version_format, Sequel.lit("api_version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'"))
      constraint(:merchants_fee_rate_range, Sequel.lit('fee_rate_scaled BETWEEN 0 AND 10000000'))
      constraint(:merchants_fee_fixed_object, Sequel.lit("jsonb_typeof(fee_fixed_minor) = 'object'"))
      constraint(:merchants_payout_interval, Sequel.lit("payout_interval IN ('daily', 'weekly', 'manual')"))
      constraint(:merchants_payout_delay_range, Sequel.lit('payout_delay_days BETWEEN 0 AND 30'))
    end
    run 'GRANT SELECT, INSERT ON merchants TO clearinghouse_app'
  end

  down do
    drop_table(:merchants)
  end
end
