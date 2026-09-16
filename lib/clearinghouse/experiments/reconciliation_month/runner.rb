# typed: true
# frozen_string_literal: true

require 'net/http'

module Clearinghouse
  module Experiments
    module ReconciliationMonth
      # Runs one simulated month and returns its measurements. See
      # docs/design/reconciliation.md, "Experiment 5", for the design and
      # results/exp5-reconciliation/ for what it produced.
      #
      # Every simulated day: at 00:30 the notification poller runs (disputes and
      # payouts), the day's settlement file is fetched and reconciled, pending lines
      # are retried and the SLA job raises missing lines; at 01:00 the availability
      # job releases matured captures and every merchant is paid out through the
      # API; then the day's traffic
      # (payments, refunds, dispute accepts and rulings) runs in time order. After
      # the traffic days, a tail of quiet days lets the last settlements, disputes
      # and payouts finish.
      class Runner
        extend T::Sig

        DAY = Clock::SECONDS_PER_DAY
        CURRENCIES = %w[usd jpy kwd].freeze
        NOTE = 'exp5: resolved by the experiment script after scoring'

        # A thing that happens at a simulated time.
        class Event < T::Struct
          const :at, Time
          const :seq, Integer
          const :action, T.proc.void
        end

        sig do
          params(config: Config, db: Sequel::Database, clock: Clock::Test, sim_url: String, driver: Driver,
                 acquirer: Acquirer::Client, lagging: Lagging).void
        end
        def initialize(config:, db:, clock:, sim_url:, driver:, acquirer:, lagging:)
          @config = config
          @db = db
          @clock = clock
          @sim_url = sim_url
          @driver = driver
          @lagging = lagging
          @rng = T.let(Random.new(config.seed), Random)
          @events = T.let([], T::Array[Event])
          @seq = T.let(0, Integer)
          @merchants = T.let([], T::Array[MerchantHandle])
          @counts = T.let({}, T::Hash[String, Integer])
          @followed = T.let({}, T::Hash[String, T::Boolean])
          @poller = T.let(Acquirer::NotificationPoller.new(db: db, client: acquirer, clock: clock,
                                                           handlers: Settlement.notification_handlers(clock: clock)),
                          Acquirer::NotificationPoller)
          @ingestor = T.let(Reconciliation::Ingestor.new(db: db, client: acquirer, clock: clock),
                            Reconciliation::Ingestor)
          @detector = T.let(Reconciliation::MissingDetector.new(db: db, clock: clock), Reconciliation::MissingDetector)
        end

        sig { returns(T::Hash[String, T.untyped]) }
        def run
          @clock.advance_to(day_time(1, 0))
          create_merchants
          plan_payments
          total_days = @config.days + @config.tail_days
          (1..total_days).each { |day| run_day(day, total_days) }
          measure
        end

        private

        sig { void }
        def create_merchants
          @merchants = Array.new(@config.merchants) do |i|
            merchant, key = Merchants.create(@db, clock: @clock, name: "Exp5 merchant #{i + 1}",
                                                  api_version: Versioning.latest)
            MerchantHandle.new(merchant: merchant, secret_key: key, currency: CURRENCIES.fetch(i % CURRENCIES.length))
          end
        end

        # The whole month's payments are drawn up front from the seed, so the traffic
        # does not depend on anything the system under test does.
        sig { void }
        def plan_payments
          @config.payments.times do
            day = @rng.rand(1..@config.days)
            at = day_time(day, 2) + @rng.rand(0...(21 * 3600))
            handle = T.must(@merchants[@rng.rand(@merchants.length)])
            amount = @rng.rand(500..50_000)
            card = payment_method
            schedule(at) { pay(handle, amount, card, plan_refund(amount)) }
          end
        end

        # [days after the payment, amount], or nil for no refund. Half are full refunds.
        sig { params(amount: Integer).returns(T.nilable([Integer, Integer])) }
        def plan_refund(amount)
          return nil unless @rng.rand < @config.refund_rate

          [@rng.rand(1..5), @rng.rand < 0.5 ? amount : @rng.rand(1..amount)]
        end

        sig { returns(String) }
        def payment_method
          roll = @rng.rand
          return 'pm_card_disputeFraudulent' if roll < @config.dispute_rate
          return 'pm_card_chargeDeclined' if roll < @config.dispute_rate + @config.decline_rate

          roll < 0.5 ? 'pm_card_visa' : 'pm_card_mastercard'
        end

        sig do
          params(handle: MerchantHandle, amount: Integer, card: String, refund: T.nilable([Integer, Integer])).void
        end
        def pay(handle, amount, card, refund)
          id = @driver.pay(handle, amount: amount, payment_method: card)
          return bump('declined') unless id

          bump('captured')
          return unless refund

          delay, refund_amount = refund
          schedule(@clock.now + (delay * DAY)) do
            status = @driver.refund(handle, payment_intent: id, amount: refund_amount)
            bump(status == 'succeeded' ? 'refunds' : 'refunds_refused')
          end
        end

        sig { params(day: Integer, total_days: Integer).void }
        def run_day(day, total_days)
          date = @config.start + (day - 1)
          @clock.advance_to(day_time(day, 0) + 1800)
          @poller.poll
          follow_new_disputes
          @ingestor.ingest(date, inject: injection(day))
          @ingestor.match_pending
          @detector.run
          @clock.advance_to(day_time(day, 1))
          Balances::Availability.release_due!(@db, clock: @clock)
          if day <= total_days - 3
            @merchants.each { |m| bump(@driver.payout(m) ? 'payouts_sent' : 'payouts_skipped') }
          end
          lagging_capture(day) if lagging_day?(day)
          run_events_until(day_time(day + 1, 0))
        end

        # K discrepancies of all six types, spread over the traffic days' files from
        # the third on (the first two have nothing due), drawn by the simulator from a
        # seed per file.
        sig { params(day: Integer).returns(T::Array[T::Hash[String, T.untyped]]) }
        def injection(day)
          window = (3..@config.days).to_a
          return [] unless window.include?(day)

          index = window.index(day).to_i
          total = @config.discrepancies
          count = (total * (index + 1) / window.length) - (total * index / window.length)
          count.positive? ? [{ 'random' => count, 'seed' => (@config.seed * 1000) + day }] : []
        end

        sig { params(day: Integer).returns(T::Boolean) }
        def lagging_day?(day)
          every = @config.lagging_every_days
          every.positive? && day >= 3 && day <= @config.days && (day % every).zero?
        end

        # A payment made through a second API whose clock is two days behind, after
        # today's file was built. Its line is due in today's file, so the acquirer
        # carries it into tomorrow's: a line that settles after its due date without
        # anything being wrong.
        sig { params(day: Integer).void }
        def lagging_capture(day)
          @lagging.clock.advance_to(day_time(day - 2, 12))
          handle = T.must(@merchants[@rng.rand(@merchants.length)])
          id = @lagging.driver.pay(handle, amount: @rng.rand(500..50_000), payment_method: 'pm_card_visa')
          bump('lagging_captures') if id
        end

        # Each dispute gets, from the day it is first seen: the merchant accepting the
        # loss a day later (sometimes), and the acquirer ruling two to four days later.
        sig { void }
        def follow_new_disputes
          @db[:disputes].where(status: 'needs_response').select_map(%i[id merchant_id acquirer_dispute_id])
                        .each do |id, merchant_id, acquirer_id|
            next if @followed[id]

            @followed[id] = true
            handle = @merchants.find { |m| m.merchant.id == merchant_id }
            if handle && @rng.rand < @config.accept_rate
              schedule(@clock.now + DAY + 3600) { @driver.accept_dispute(handle, dispute: id) }
            end
            outcome = @rng.rand < 0.5 ? 'won' : 'lost'
            schedule(@clock.now + (@rng.rand(2..4) * DAY) + 7200) { rule(acquirer_id, outcome) }
          end
        end

        # The card network's ruling, through the simulator's admin endpoint.
        sig { params(acquirer_id: String, outcome: String).void }
        def rule(acquirer_id, outcome)
          uri = URI("#{@sim_url}/admin/disputes/#{acquirer_id}/resolve")
          request = Net::HTTP::Post.new(uri)
          request['Sim-Time'] = @clock.now.utc.iso8601(6)
          request['Content-Type'] = 'application/json'
          request.body = JSON.generate('outcome' => outcome)
          response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
          raise "ruling on #{acquirer_id} failed: #{response.code} #{response.body}" unless response.code == '200'

          bump("disputes_#{outcome}_at_acquirer")
        end

        sig { params(key: String).void }
        def bump(key)
          @counts[key] = @counts.fetch(key, 0) + 1
        end

        sig { params(at: Time, action: T.proc.void).void }
        def schedule(at, &action)
          @events << Event.new(at: at, seq: @seq += 1, action: action)
        end

        sig { params(limit: Time).void }
        def run_events_until(limit)
          loop do
            due = @events.select { |e| e.at < limit }.min_by { |e| [e.at, e.seq] }
            break unless due

            @events.delete(due)
            @clock.advance_to(due.at) if due.at > @clock.now
            due.action.call
          end
        end

        sig { params(day: Integer, hour: Integer).returns(Time) }
        def day_time(day, hour)
          date = @config.start + (day - 1)
          Time.utc(date.year, date.month, date.day, hour)
        end

        sig { returns(T::Hash[String, T.untyped]) }
        def measure
          exceptions = @db[:reconciliation_exceptions].order(:created_at, :id).all
          manifests = @db[:settlement_files].order(:settled_on).select_map(:settled_on).map { |d| manifest(d) }
          score = Scorer.new(manifests: manifests, exceptions: exceptions).score
          before = explainability
          invariants_before = Ledger::Invariants.check(@db).length
          resolutions = resolve_all
          {
            'workload' => workload, 'score' => score,
            'exceptions_by_reason' => exceptions.group_by { |x| x.fetch(:reason) }.transform_values(&:length),
            'explainability_before_resolving' => before, 'resolutions' => resolutions,
            'explainability_after_resolving' => explainability,
            'invariant_violations' => { 'before' => invariants_before,
                                        'after' => Ledger::Invariants.check(@db).length },
            'balance_drifts' => Ledger::Checker.run(@db).drifts.length
          }
        end

        sig { returns(T::Hash[String, Integer]) }
        def resolve_all
          counts = T.let({}, T::Hash[String, Integer])
          @db[:reconciliation_exceptions].where(status: 'open').order(:created_at, :id).all.each do |x|
            action = x.fetch(:unexplained_amount).zero? ? 'none' : 'write_off'
            @driver.resolve_exception(x.fetch(:id), action: action, note: NOTE)
            counts[action] = counts.fetch(action, 0) + 1
          end
          counts
        end

        sig { returns(T::Array[T::Hash[String, T.untyped]]) }
        def explainability
          slas = Reconciliation::DataQuality.default_slas(Reconciliation::Config.new)
          report = Ledger::Clearing.report(@db, as_of: @clock.now, slas: slas)
          report.explainability.map do |e|
            { 'flow_type' => e.flow_type, 'currency' => e.currency, 'flows' => e.flows,
              'explained_flows' => e.explained_flows, 'volume' => e.volume, 'explained_volume' => e.explained_volume,
              'share' => e.share.to_f.round(6) }
          end
        end

        sig { returns(T::Hash[String, Integer]) }
        def workload
          lines = @db[:settlement_lines].group_and_count(:outcome).to_h { |r| [r.fetch(:outcome), r.fetch(:count)] }
          @counts.merge(counted(:payouts, :status, 'payouts'), counted(:disputes, :status, 'disputes'),
                        counted(:disputes, :closed_by, 'disputes_closed_by'), lines.transform_keys { |k| "lines_#{k}" })
                 .merge('payments_planned' => @config.payments,
                        'payment_intents_succeeded' => @db[:payment_intents].where(status: 'succeeded').count,
                        'disputes_opened' => @db[:disputes].count, 'settlement_files' => @db[:settlement_files].count,
                        'settlement_lines' => lines.values.sum)
        end

        # {"<prefix>_<value>" => rows} for one column of one table, nulls left out.
        sig { params(table: Symbol, column: Symbol, prefix: String).returns(T::Hash[String, Integer]) }
        def counted(table, column, prefix)
          @db[table].exclude(column => nil).group_and_count(column)
                    .to_h { |r| ["#{prefix}_#{r.fetch(column)}", r.fetch(:count)] }
        end

        sig { params(date: Date).returns(T::Hash[String, T.untyped]) }
        def manifest(date)
          JSON.parse(Net::HTTP.get(URI("#{@sim_url}/admin/settlement_files/#{date.iso8601}/manifest")))
        end
      end
    end
  end
end
