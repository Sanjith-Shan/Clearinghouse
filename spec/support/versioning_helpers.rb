# typed: false
# frozen_string_literal: true

module VersioningSpecHelpers
  FIXTURES = File.expand_path('../fixtures/resources', __dir__)

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json")))
  end

  # A change built inline, for engine specs that need one the API does not ship.
  def build_change(version:, resources: ['payment_intent'], description: 'test change', &transform)
    Class.new(Clearinghouse::Versioning::VersionChange) do
      define_method(:version) { version }
      define_method(:description) { description }
      define_method(:resources) { resources }
      define_method(:transform) { |object| transform ? transform.call(object) : object }
    end.new
  end
end

RSpec.configure { |c| c.include VersioningSpecHelpers }
