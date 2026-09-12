# typed: false
# frozen_string_literal: true

# Mutant hooks, loaded by .mutant.yml. `hooks` is mutant's hook builder.
#
# Mutant forks one worker per job and runs each mutation's tests inside it. The ledger
# specs truncate and write Postgres tables, so two workers on one database would see
# each other's rows. Each worker gets its own database, named after the job index;
# bin/mutation creates and migrates them before mutant starts. Workers connect lazily
# (DBHelper opens nothing until the first :db example), so setting the name here, at
# the start of the forked worker, is early enough.
base = ENV.fetch('CLEARINGHOUSE_DB', 'clearinghouse_test')

hooks.register(:mutation_worker_process_start) do |index:|
  ENV['CLEARINGHOUSE_DB'] = "#{base}_#{index}"
end

# `mutant environment test run` runs the suite through the same workers.
hooks.register(:test_worker_process_start) do |index:|
  ENV['CLEARINGHOUSE_DB'] = "#{base}_#{index}"
end
