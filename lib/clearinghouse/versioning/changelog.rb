# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Versioning
    # Builds docs/api-changelog.md from the registered changes, so the changelog is
    # whatever the code does and cannot drift from it. A spec fails if the
    # committed file is stale; bin/changelog rewrites it.
    module Changelog
      extend T::Sig

      PATH = File.expand_path('../../../docs/api-changelog.md', __dir__)

      sig { params(registry: Registry).returns(String) }
      def self.render(registry)
        lines = [
          '# API changelog',
          '',
          'Generated from the version change modules in `lib/clearinghouse/versioning/changes/` by',
          '`bin/changelog`. Do not edit by hand.',
          '',
          "Latest version: `#{registry.latest}`. A merchant is pinned to the latest version when it is",
          'created. Send `Clearinghouse-Version: <date>` to use another version for one request.',
          ''
        ]
        registry.versions.reverse_each do |version|
          lines << "## #{version}" << ''
          changes = registry.changes.select { |change| change.version == version }
          if changes.empty?
            lines << 'The first version of the API.'
          else
            changes.each do |change|
              lines << "- **#{change.resources.join(', ')}**: #{change.description}"
            end
          end
          lines << ''
        end
        "#{lines.join("\n").rstrip}\n"
      end
    end
  end
end
