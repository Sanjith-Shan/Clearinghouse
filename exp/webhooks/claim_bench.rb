# typed: true
# frozen_string_literal: true

require 'json'
require_relative '../../lib/clearinghouse'

module Experiments
  module Webhooks
    # How fast each queue can hand out deliveries, with no HTTP at all: T threads in
    # one process claim a delivery and immediately mark it succeeded, until none are
    # left. Setup is 100 endpoints over 25 merchants and `events` events, each fanned
    # out to its merchant's 4 endpoints. Runs against the experiment database, which
    # it empties first.
    #
    #   bundle exec ruby exp/webhooks/claim_bench.rb [threads] [events]
    module ClaimBench
      extend T::Sig

      sig { params(database: String, threads: Integer, events: Integer).returns(T::Array[T::Hash[String, T.untyped]]) }
      def self.run(database:, threads:, events:)
        db = Clearinghouse::DB.connect(role: :app, database: database, max_connections: threads + 2)
        setup(db, events)
        queues = { 'fifo' => Clearinghouse::Webhooks::FifoQueue.new,
                   'isolated' => Clearinghouse::Webhooks::IsolatedQueue.new(max_in_flight: 2) }
        queues.map do |name, queue|
          reset(db)
          measure(db, name, queue, threads)
        end
      ensure
        db&.disconnect
      end

      sig { params(db: Sequel::Database, events: Integer).void }
      def self.setup(db, events)
        clock = Clearinghouse::Clock::Real.new
        http = Clearinghouse::Webhooks::SafeHttp.new(resolver: Clearinghouse::Webhooks::Egress::SystemResolver.new,
                                                     test_mode: true)
        merchants = Array.new(25) do |i|
          Clearinghouse::Merchants.create(db, clock: clock, name: "bench #{i}", api_version: '2026-09-01').first.id
        end
        100.times do |n|
          Clearinghouse::Webhooks::Endpoints.create(db, clock: clock, merchant_id: merchants.fetch(n % 25),
                                                        url: "http://127.0.0.1:9/e/#{n}", enabled_events: ['*'],
                                                        api_version: '2026-09-01', url_check: ->(url) { http.pin(url) })
        end
        rng = Random.new(1)
        events.times do |i|
          object = { 'id' => "pi_bench#{i}", 'object' => 'payment_intent' }
          Clearinghouse::Events.emit!(db, merchant_id: merchants.fetch(rng.rand(25)), type: 'payment_intent.succeeded',
                                          object: object, clock: clock)
        end
        Clearinghouse::Webhooks::Dispatcher.new(db: db, clock: clock).run_until_idle
      end

      sig { params(db: Sequel::Database).void }
      def self.reset(db)
        db[:webhook_deliveries].update(status: 'pending', succeeded_at: nil, lease_token: nil, lease_expires_at: nil,
                                       attempts: 0)
      end

      sig do
        params(db: Sequel::Database, name: String, queue: Clearinghouse::Webhooks::Queue, threads: Integer)
          .returns(T::Hash[String, T.untyped])
      end
      def self.measure(db, name, queue, threads)
        now = Time.now + 60
        total = db[:webhook_deliveries].count
        counts = { claimed: 0, empty: 0 }
        mutex = Mutex.new
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Array.new(threads) do |i|
          Thread.new do
            loop do
              claim = queue.claim(db, now: now, lease_seconds: 60, token: "bench#{i}")
              if claim
                db[:webhook_deliveries].where(id: claim.delivery_id)
                                       .update(status: 'succeeded', succeeded_at: now, lease_token: nil,
                                               lease_expires_at: nil)
                mutex.synchronize { counts[:claimed] += 1 }
              else
                mutex.synchronize { counts[:empty] += 1 }
                break if db[:webhook_deliveries].where(status: 'pending').empty?
              end
            end
          end
        end.each(&:join)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f - started
        { 'queue' => name, 'threads' => threads, 'deliveries' => total, 'claimed' => counts[:claimed],
          'empty_claims' => counts[:empty], 'seconds' => elapsed.round(2),
          'per_second' => (counts[:claimed] / elapsed).round }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require_relative 'driver'
  database = ENV.fetch('CLEARINGHOUSE_EXP_DB', 'clearinghouse_exp_webhooks')
  settings = Experiments::Webhooks::Driver::Settings.new(raw_dir: Dir.pwd, database: database)
  Experiments::Webhooks::Driver.new(settings).send(:reset_database!)
  rtt_db = Clearinghouse::DB.connect(role: :app, database: database, max_connections: 1)
  rtt_db.run('SELECT 1')
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  200.times { rtt_db.run('SELECT 1') }
  rtt_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f - t0) / 200 * 1000).round(2)
  rtt_db.disconnect
  results = Experiments::Webhooks::ClaimBench.run(database: database, threads: Integer(ARGV.fetch(0, '32'), 10),
                                                  events: Integer(ARGV.fetch(1, '375'), 10))
  puts JSON.generate({ 'round_trip_ms' => rtt_ms, 'results' => results })
end
