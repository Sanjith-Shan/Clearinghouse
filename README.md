# Clearinghouse: Payments API and Double-Entry Ledger

A payments API in Ruby with an append-only double-entry ledger in Postgres, built to show
that money is never created, lost, or moved twice, and to measure it.

**It is a simulation.** The acquirer, the card networks and the banks are simulated. Payment
methods are test tokens like `pm_card_visa`. There are no card numbers, no PAN storage and no
PCI scope. No real money moves.

Work in progress. See `CONTRIBUTING.md` to run it.
