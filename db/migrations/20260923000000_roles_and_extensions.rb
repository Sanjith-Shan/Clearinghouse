# typed: false
# frozen_string_literal: true

# Baseline grants. Every later migration that adds a table grants the app role
# exactly the privileges it needs, and ledger tables never get UPDATE or DELETE.
Sequel.migration do
  up do
    run 'GRANT USAGE ON SCHEMA public TO clearinghouse_app'
    run 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO clearinghouse_app'
  end

  down do
    run 'ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE USAGE, SELECT ON SEQUENCES FROM clearinghouse_app'
  end
end
