# typed: false
# frozen_string_literal: true

require 'fileutils'

# Every resource fixture rendered at every version, compared byte for byte with a
# committed golden file. A change to any transform shows up as a diff in review.
# Regenerate with: UPDATE_GOLDEN=1 bundle exec rspec spec/versioning/golden_spec.rb
module GoldenFiles
  FIXTURES = File.expand_path('../fixtures/resources', __dir__)
  GOLDEN = File.expand_path('../fixtures/golden', __dir__)
  NAMES = Dir[File.join(FIXTURES, '*.json')].map { |f| File.basename(f, '.json') }.sort.freeze
end

RSpec.describe Clearinghouse::Versioning do
  let(:fixtures_dir) { GoldenFiles::FIXTURES }
  let(:golden_dir) { GoldenFiles::GOLDEN }
  let(:fixture_names) { GoldenFiles::NAMES }

  def render(fixture, version)
    engine = Clearinghouse::Versioning.engine
    fixture['object'] == 'event' ? engine.render_event(fixture, version) : engine.render(fixture, version)
  end

  it 'has fixtures to render' do
    expect(fixture_names).to include('payment_intent', 'payment_intent_list', 'event_payment_intent_succeeded')
  end

  described_class.registry.versions.each do |version|
    GoldenFiles::NAMES.each do |name|
      it "renders #{name} at #{version}" do
        fixture = JSON.parse(File.read(File.join(fixtures_dir, "#{name}.json")))
        rendered = "#{JSON.pretty_generate(render(fixture, version))}\n"
        golden = File.join(golden_dir, version, "#{name}.json")
        if ENV['UPDATE_GOLDEN']
          FileUtils.mkdir_p(File.dirname(golden))
          File.write(golden, rendered)
        end
        expect(File.exist?(golden)).to be(true), "missing #{golden}; run with UPDATE_GOLDEN=1"
        expect(rendered).to eq(File.read(golden))
      end
    end
  end

  it 'has no golden files for versions or fixtures that no longer exist' do
    expected = described_class.registry.versions.product(fixture_names).map do |v, n|
      File.join(golden_dir, v, "#{n}.json")
    end
    expect(Dir[File.join(golden_dir, '*', '*.json')]).to eq(expected.sort)
  end

  it 'renders the latest version as the fixture itself' do
    fixture_names.reject { |n| n.start_with?('event_') }.each do |name|
      fixture = JSON.parse(File.read(File.join(fixtures_dir, "#{name}.json")))
      expect(render(fixture, described_class.latest)).to eq(fixture)
    end
  end

  it 'keeps the list and event fixtures in step with the payment_intent fixtures' do
    load = ->(n) { JSON.parse(File.read(File.join(fixtures_dir, "#{n}.json"))) }
    expect(load.call('payment_intent_list')['data']).to eq([load.call('payment_intent'),
                                                            load.call('payment_intent_declined')])
    expect(load.call('event_payment_intent_succeeded')['data']['object']).to eq(load.call('payment_intent'))
  end
end
