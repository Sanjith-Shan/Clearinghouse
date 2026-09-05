# typed: true
# frozen_string_literal: true

# `bundle exec puma sim/config.ru` works, but bin/sim is the supported way in: it pins
# Puma to a single process, which the in-memory state depends on.
require_relative 'lib/acquirer_sim'

run AcquirerSim::App.new
