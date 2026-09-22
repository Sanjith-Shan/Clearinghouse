# typed: false
# frozen_string_literal: true

ENV['CLEARINGHOUSE_ENV'] = 'test'
ENV['RACK_ENV'] = 'test'

unless ENV['NO_COVERAGE']
  require 'simplecov'
  require_relative 'coverage_groups'
  SimpleCov.start do
    enable_coverage :branch
    primary_coverage :branch
    add_filter '/spec/'
    add_filter '/vendor/'
    CoverageGroups::GROUPS.each do |name, claims|
      add_group(name) { |file| claims.call(file.project_filename.delete_prefix('/')) }
    end
    minimum_coverage_by_file line: 0
  end

  # The branch-coverage floors in spec/coverage_groups.rb. Only bin/ci sets
  # COVERAGE_GATE, because only a full run means anything: a single spec file would
  # fail every floor. The gate is skipped when the examples already failed, so a red
  # run reports the failing examples rather than a coverage number.
  if ENV['COVERAGE_GATE'] == '1'
    SimpleCov.at_exit do
      SimpleCov.result.format!
      examples_failed = $ERROR_INFO.is_a?(SystemExit) && !$ERROR_INFO.success?
      missed = CoverageGroups.violations(CoverageGroups.hits_from(SimpleCov.result))
      unless examples_failed || missed.empty?
        warn "Coverage gate failed:\n#{missed.map { |m| "  #{m}" }.join("\n")}"
        Kernel.exit(2)
      end
    end
  end
end

require 'bundler/setup'
require_relative '../lib/clearinghouse'
require 'prop_check'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  # Examples tagged :timing assert tight wall-clock bounds (a deadline's overrun
  # in milliseconds) that only hold on a quiet machine. Every one of them has a
  # load-tolerant twin that always runs. See docs/design/testing-timing.md.
  config.filter_run_excluding :timing unless ENV['CLEARINGHOUSE_STRICT_TIMING'] == '1'
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
