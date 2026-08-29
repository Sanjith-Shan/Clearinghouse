-- The owner role runs migrations. The app connects as clearinghouse_app, which is
-- granted INSERT and SELECT on the ledger and nothing that edits history.
CREATE ROLE clearinghouse_app LOGIN PASSWORD 'app';
CREATE DATABASE clearinghouse_test OWNER clearinghouse_owner;
