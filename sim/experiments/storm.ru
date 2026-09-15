# typed: true
# frozen_string_literal: true

# The API as experiment 1 serves it: the real routes plus the two storm baselines
# (lib/clearinghouse/experiments/storm_baselines.rb). bin/storm starts it on Puma with
# CLEARINGHOUSE_ENV=experiment; StormBaselines.rack_app refuses to build otherwise.
#
# Wired like Dependencies.from_env, minus RiskGate: risk is not what this experiment
# measures, and a risk call would add the same noise to all three implementations.

require 'bundler/setup'
require_relative '../../lib/clearinghouse'
require_relative '../../lib/clearinghouse/experiments/storm_baselines'

clock = Clearinghouse::Clock::Real.new
log = ENV.fetch('STORM_REQUEST_LOG', nil)
deps = Clearinghouse::Api::Dependencies.new(
  db: Clearinghouse::DB.connect(role: :app, max_connections: Integer(ENV.fetch('CLEARINGHOUSE_DB_POOL', '10'), 10)),
  clock: clock,
  acquirer: Clearinghouse::Acquirer::Client.new(clock: clock),
  # Open for the life of the process, which is the life of the server.
  log: log && File.open(log, 'a').tap { |f| f.sync = true } # rubocop:disable Style/FileOpen
)
on_unknown = Clearinghouse::Experiments::StormBaselines::OnUnknown.deserialize(ENV.fetch('STORM_ON_UNKNOWN', 'fail'))
run Clearinghouse::Experiments::StormBaselines.rack_app(deps, on_unknown: on_unknown)
