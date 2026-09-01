# typed: false
# frozen_string_literal: true

require 'ipaddr'

# A resolver that answers from a script and counts lookups. Give a host a list of
# answers to make it change its mind between lookups, the way a rebinding DNS server does.
class FakeResolver
  include Clearinghouse::Webhooks::Egress::Resolver

  attr_reader :lookups

  def initialize(records)
    @records = records.transform_values { |answers| answers.map { |answer| Array(answer) } }
    @lookups = Hash.new(0)
  end

  def resolve(hostname)
    answers = @records.fetch(hostname) do
      raise Clearinghouse::Webhooks::Egress::Resolver::ResolutionError, "#{hostname}: NXDOMAIN"
    end
    answer = answers[[@lookups[hostname], answers.length - 1].min]
    @lookups[hostname] += 1
    answer.map { |ip| IPAddr.new(ip) }
  end
end
