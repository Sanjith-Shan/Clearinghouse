# frozen_string_literal: true

require_relative 'lib/clearinghouse_client/version'

Gem::Specification.new do |spec|
  spec.name = 'clearinghouse_client'
  spec.version = ClearinghouseClient::VERSION
  spec.authors = ['Sanjith Shanmugavel']
  spec.summary = 'Ruby client for the Clearinghouse payments API, with safe automatic retries'
  spec.description = 'Idempotency keys reused across retries, backoff with full jitter, typed errors, ' \
                     'pagination and webhook signature verification. Standard library only.'
  spec.homepage = 'https://github.com/Sanjith-Shan/Clearinghouse'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3'
  spec.files = Dir['lib/**/*.rb']
  spec.require_paths = ['lib']
  spec.metadata['rubygems_mfa_required'] = 'true'
  # No runtime dependencies on purpose: see lib/clearinghouse_client/sorbet_stub.rb.
end
