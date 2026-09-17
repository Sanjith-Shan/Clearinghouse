# typed: true
# frozen_string_literal: true

require_relative '../../lib/clearinghouse'

module Experiments
  # Experiment 2: crash the real server at every recovery point of every flow in
  # the idempotency registry, restart it, recover, and check that nothing was
  # lost, doubled or changed. docs/design/crash-matrix.md explains the method;
  # bin/crash-matrix runs it.
  module CrashMatrix
    extend T::Sig
  end
end

require_relative 'crash_matrix/processes'
require_relative 'crash_matrix/proxy'
require_relative 'crash_matrix/api_client'
require_relative 'crash_matrix/inspector'
require_relative 'crash_matrix/scenarios'
require_relative 'crash_matrix/case_runner'
require_relative 'crash_matrix/verifier'
require_relative 'crash_matrix/matrix'
require_relative 'crash_matrix/report'
require_relative 'crash_matrix/session'
