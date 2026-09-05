# typed: false
# frozen_string_literal: true

require 'json'

# The shared webhook signature vectors, parsed once.
module SignatureVectors
  PATH = File.expand_path('../fixtures/signatures.json', __dir__)

  # RiskGate's own vectors, copied from its repo. Both verifiers must pass both files.
  RISKGATE_PATH = File.expand_path('../fixtures/signatures_riskgate.json', __dir__)

  def self.all
    @all ||= JSON.parse(File.read(PATH, encoding: 'UTF-8')).freeze
  end

  def self.riskgate
    @riskgate ||= JSON.parse(File.read(RISKGATE_PATH, encoding: 'UTF-8')).freeze
  end
end
