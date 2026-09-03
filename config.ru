# typed: true
# frozen_string_literal: true

require 'bundler/setup'
require_relative 'lib/clearinghouse'

run Clearinghouse::Api.rack_app(Clearinghouse::Api::Dependencies.from_env)
