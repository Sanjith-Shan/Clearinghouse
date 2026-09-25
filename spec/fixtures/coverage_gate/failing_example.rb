# typed: false
# frozen_string_literal: true

# Run only by spec/unit/coverage_groups_spec.rb, in a child rspec: one failing
# example, so the coverage gate must stay out of the way. Not named *_spec.rb, so
# the suite itself never runs it.
RSpec.describe 'a suite with a failing example' do
  it('fails') { expect(1).to eq(2) }
end
