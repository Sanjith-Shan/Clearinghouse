# typed: false
# frozen_string_literal: true

ENV['CLEARINGHOUSE_ENV'] = 'test'
ENV['RACK_ENV'] = 'test'

unless ENV['NO_COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    enable_coverage :branch
    primary_coverage :branch
    add_filter '/spec/'
    add_filter '/vendor/'
    add_group 'Ledger', 'lib/clearinghouse/ledger'
    add_group 'Idempotency', 'lib/clearinghouse/idempotency'
    minimum_coverage_by_file line: 0
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
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
