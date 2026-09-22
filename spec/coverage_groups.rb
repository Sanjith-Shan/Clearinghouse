# typed: false
# frozen_string_literal: true

# Coverage groups and the branch-coverage floors bin/ci enforces. Shared by
# spec_helper (SimpleCov groups and the gate) and bin/quality-report (the
# experiment 7 table), so the report and the gate can never disagree about what
# "the ledger" means.
module CoverageGroups
  MONEY_CORE = %w[lib/clearinghouse/money.rb lib/clearinghouse/currency.rb lib/clearinghouse/fees.rb].freeze

  # name => predicate on a path relative to the project root. Ordered; a file
  # belongs to the first group that claims it.
  GROUPS = {
    'Ledger' => ->(path) { path == 'lib/clearinghouse/ledger.rb' || path.start_with?('lib/clearinghouse/ledger/') },
    'Money core' => ->(path) { MONEY_CORE.include?(path) },
    'Idempotency' => ->(path) { path.start_with?('lib/clearinghouse/idempotency') },
    'Webhooks' => ->(path) { path.start_with?('lib/clearinghouse/webhooks') },
    'API' => ->(path) { path.start_with?('lib/clearinghouse/api') },
    'Versioning' => ->(path) { path.start_with?('lib/clearinghouse/versioning') },
    'Acquirer client' => ->(path) { path.start_with?('lib/clearinghouse/acquirer') },
    'Other lib' => ->(path) { path.start_with?('lib/') },
    'Simulator' => ->(path) { path.start_with?('sim/') },
    'Ruby client' => ->(path) { path.start_with?('clients/ruby/') }
  }.freeze

  # Branch coverage floors, in percent. The ledger and the money core are held to
  # the spec's 95%. The global floor sits just below what main measured when the
  # gate was added (93.84%, 883 of 941 branches, on 2026-09-24), so it catches a
  # real drop without failing on noise. Raise it when coverage goes up; never lower
  # it to get green.
  GROUP_FLOORS = { 'Ledger' => 95.0, 'Money core' => 95.0 }.freeze
  GLOBAL_FLOOR = 93.5

  def self.group_of(path)
    GROUPS.find { |_, claims| claims.call(path) }&.first
  end

  # {group => [covered, total]} from {path relative to root => [hit count per branch]}.
  def self.branch_totals(hits_by_path)
    totals = Hash.new { |h, k| h[k] = [0, 0] }
    hits_by_path.each do |path, hits|
      group = group_of(path) or next
      totals[group][0] += hits.count(&:positive?)
      totals[group][1] += hits.length
    end
    totals
  end

  def self.percent(covered, total)
    total.zero? ? 100.0 : (100.0 * covered / total)
  end

  # Branch hit counts per file from a SimpleCov result, skipping `:nocov:` branches
  # the same way SimpleCov's own totals do.
  def self.hits_from(result)
    result.files.to_h do |file|
      [file.project_filename.delete_prefix('/'), file.branches.reject(&:skipped?).map(&:coverage)]
    end
  end

  # Floors that were missed, as lines to print. Empty when everything holds.
  def self.violations(hits_by_path)
    totals = branch_totals(hits_by_path)
    missed = GROUP_FLOORS.filter_map do |group, floor|
      covered, total = totals[group]
      actual = percent(covered, total)
      "#{group}: branch coverage #{format('%.2f', actual)}% is below #{floor}%" if actual < floor
    end
    covered = totals.values.sum(&:first)
    total = totals.values.sum(&:last)
    actual = percent(covered, total)
    missed << "all code: branch coverage #{format('%.2f', actual)}% is below #{GLOBAL_FLOOR}%" if actual < GLOBAL_FLOOR
    missed
  end
end
