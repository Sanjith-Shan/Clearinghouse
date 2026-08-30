# typed: false
# frozen_string_literal: true

require 'json'

# The shared webhook signature vectors, parsed once.
module SignatureVectors
  PATH = File.expand_path('../fixtures/signatures.json', __dir__)

  def self.all
    @all ||= JSON.parse(File.read(PATH, encoding: 'UTF-8')).freeze
  end
end
