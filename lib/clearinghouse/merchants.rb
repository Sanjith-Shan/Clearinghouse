# typed: true
# frozen_string_literal: true

require 'digest'
require 'json'
require 'rack/utils'

module Clearinghouse
  # A merchant: who the money is for, how it is charged fees, when it is paid out,
  # and which API version its integration was written against.
  class Merchant < T::Struct
    extend T::Sig

    const :id, String
    const :name, String
    const :api_version, String
    const :fee_schedule, FeeSchedule
    const :payout_interval, String
    const :payout_delay_days, Integer
    const :secret_key_last4, String
    const :created_at, Time

    # The latest-version API representation. It is `object: "account"` because
    # that is what a merchant is called on the wire in Stripe's API, which the
    # Integration round practises reading.
    sig { returns(T::Hash[String, T.untyped]) }
    def to_api
      {
        'id' => id,
        'object' => 'account',
        'name' => name,
        'api_version' => api_version,
        'fee_schedule' => {
          'percent' => Merchants.percent_string(fee_schedule.rate_scaled),
          'fixed' => fee_schedule.fixed_minor
        },
        'payout_schedule' => { 'interval' => payout_interval, 'delay_days' => payout_delay_days },
        'created' => created_at.to_i,
        'livemode' => false
      }
    end
  end

  # Creating merchants and finding them by secret key.
  #
  # Keys are `sk_test_` plus 24 base62 characters from SecureRandom, about 143 bits,
  # and only their SHA-256 digest is stored. A slow password hash (bcrypt, scrypt)
  # exists to make guessing a low-entropy password expensive; nobody can guess a
  # 143-bit random key at any hash speed, so the slowness would buy nothing. It
  # would also put a deliberately slow hash on every API request, and bcrypt's per-row
  # salt would make lookup by digest impossible, forcing a scan of every merchant.
  module Merchants
    extend T::Sig

    KEY_PREFIX = 'sk_test'
    PAYOUT_INTERVALS = %w[daily weekly manual].freeze
    DEFAULT_PAYOUT_DELAY_DAYS = 2

    sig do
      params(db: Sequel::Database, clock: Clock, name: String, api_version: String,
             fee_schedule: FeeSchedule, payout_interval: String,
             payout_delay_days: Integer).returns([Merchant, String])
    end
    def self.create(db, clock:, name:, api_version:, fee_schedule: FeeSchedule.us_card_default,
                    payout_interval: 'daily', payout_delay_days: DEFAULT_PAYOUT_DELAY_DAYS)
      secret_key = Ids.generate(KEY_PREFIX)
      merchant = Merchant.new(
        id: Ids.generate('acct'), name: name, api_version: api_version, fee_schedule: fee_schedule,
        payout_interval: payout_interval, payout_delay_days: payout_delay_days,
        secret_key_last4: secret_key[-4..].to_s, created_at: clock.now
      )
      db[:merchants].insert(
        id: merchant.id, name: name, api_version: api_version, secret_key_hash: digest(secret_key),
        secret_key_last4: merchant.secret_key_last4, fee_rate_scaled: fee_schedule.rate_scaled,
        fee_fixed_minor: Sequel.cast(JSON.generate(fee_schedule.fixed_minor), :jsonb),
        payout_interval: payout_interval, payout_delay_days: payout_delay_days, created_at: merchant.created_at
      )
      [merchant, secret_key]
    end

    # The merchant whose key this is, or nil. Keys of the wrong shape are rejected
    # without a query. The lookup is by digest through a unique index, so its timing
    # depends on the digest of the attacker's guess, never on a stored secret, and
    # learning that SHA-256(guess) shares a prefix with a stored digest does not help
    # find a key. The final comparison is constant-time anyway, so the one place a
    # stored value meets a caller's value never short-circuits.
    sig { params(db: Sequel::Database, secret_key: String).returns(T.nilable(Merchant)) }
    def self.authenticate(db, secret_key)
      return nil unless Ids.valid?(secret_key, KEY_PREFIX)

      wanted = digest(secret_key)
      row = db[:merchants].where(secret_key_hash: wanted).first
      return nil unless row && Rack::Utils.secure_compare(row[:secret_key_hash], wanted)

      from_row(row)
    end

    sig { params(db: Sequel::Database, id: String).returns(T.nilable(Merchant)) }
    def self.find(db, id)
      row = db[:merchants].where(id: id).first
      row ? from_row(row) : nil
    end

    sig { params(secret_key: String).returns(String) }
    def self.digest(secret_key)
      Digest::SHA256.hexdigest(secret_key)
    end

    # "2.9" <-> 290_000 in FeeSchedule's scale, exactly, with no Float in between.
    sig { params(text: String).returns(Integer) }
    def self.parse_percent(text)
      match = /\A(\d{1,3})(?:\.(\d{1,5}))?\z/.match(text)
      raise ArgumentError, "not a percentage: #{text.inspect}" unless match

      whole = Integer(T.must(match[1]), 10)
      fraction = Integer((match[2] || '').ljust(5, '0'), 10)
      scaled = (whole * 100_000) + fraction
      raise ArgumentError, "#{text}% is over 100%" if scaled > FeeSchedule::SCALE

      scaled
    end

    sig { params(rate_scaled: Integer).returns(String) }
    def self.percent_string(rate_scaled)
      whole, fraction = rate_scaled.divmod(100_000)
      fraction.zero? ? whole.to_s : "#{whole}.#{fraction.to_s.rjust(5, '0').sub(/0+\z/, '')}"
    end

    sig { params(row: T::Hash[Symbol, T.untyped]).returns(Merchant) }
    def self.from_row(row)
      fixed = row[:fee_fixed_minor]
      fixed = JSON.parse(fixed) if fixed.is_a?(String)
      Merchant.new(
        id: row[:id], name: row[:name], api_version: row[:api_version],
        fee_schedule: FeeSchedule.new(rate_scaled: row[:fee_rate_scaled], fixed_minor: fixed.to_h),
        payout_interval: row[:payout_interval], payout_delay_days: row[:payout_delay_days],
        secret_key_last4: row[:secret_key_last4], created_at: row[:created_at].utc
      )
    end
  end
end
