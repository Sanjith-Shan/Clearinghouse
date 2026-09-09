# typed: strict
# frozen_string_literal: true

require 'securerandom'

module Clearinghouse
  # Object ids in the `pi_...` shape: a registered prefix, an underscore, and 24
  # base62 characters from SecureRandom (about 143 bits). The prefix makes an id
  # self-describing in logs and support tickets, and it is also how flow ids tell
  # the ledger which kind of flow they belong to.
  module Ids
    extend T::Sig

    RANDOM_LENGTH = 24

    # Every prefix in use, by the object it names. Adding an object type means adding
    # its prefix here, so two types can never quietly share one.
    PREFIXES = T.let({
      'account' => 'acct',
      'charge' => 'ch',
      'dispute' => 'dp',
      'event' => 'evt',
      'ledger_transaction' => 'txn',
      'payment_intent' => 'pi',
      'payment_method' => 'pm',
      'payout' => 'po',
      'reconciliation_exception' => 'rex',
      'refund' => 're',
      'review' => 'prv',
      'request' => 'req',
      'secret_key' => 'sk_test',
      'webhook_delivery' => 'whd',
      'webhook_endpoint' => 'we'
    }.freeze, T::Hash[String, String])

    class UnknownPrefixError < Clearinghouse::Error; end

    sig { params(prefix: String).returns(String) }
    def self.generate(prefix)
      raise UnknownPrefixError, "unregistered id prefix #{prefix.inspect}" unless PREFIXES.value?(prefix)

      # SecureRandom.alphanumeric draws each character uniformly from [A-Za-z0-9],
      # so there is no modulo bias.
      "#{prefix}_#{SecureRandom.alphanumeric(RANDOM_LENGTH)}"
    end

    sig { params(id: T.untyped, prefix: String).returns(T::Boolean) }
    def self.valid?(id, prefix)
      return false unless id.is_a?(String)

      /\A#{Regexp.escape(prefix)}_[A-Za-z0-9]{#{RANDOM_LENGTH}}\z/.match?(id)
    end
  end
end
