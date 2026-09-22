# typed: true
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'rbconfig'

module Experiments
  # Experiment 2 (sim/experiments/crash_matrix.rb): crash points outside any
  # request. Disputes and payout answers reach Clearinghouse through bin/poller,
  # not through an HTTP request, so they are not in Payments::Flows.registry.
  # Settlement.background_crash_points lists bin/poller's recovery points per
  # notification type, and each becomes a case here: set the world up until one
  # notification of that type is due, run a real bin/poller armed to exit!(86) at
  # the point, run a clean one, poll once more, and compare with an uninterrupted
  # control notification of the same kind.
  module CrashMatrix
    # How far ahead of the wall clock bin/poller (and the harness's own polls)
    # run: past the simulator's dispute_after_days (7) and a payout's day at the
    # bank, so whatever the setup made is due.
    POLLER_AHEAD_S = 8 * Clearinghouse::Clock::SECONDS_PER_DAY

    DISPUTED_AMOUNT = 2000
    DISPUTE_FEE = 1500 # Disputes::FeePolicy's USD fee, written out so a change to it shows here

    # What a background scenario can do to the world: API requests to a clean API
    # process, and the things no endpoint does (the availability sweep, the
    # harness's own poll, the acquirer ruling on a dispute).
    class BackgroundWorld
      extend T::Sig

      sig { returns(ApiClient) }
      attr_reader :api

      sig { returns(Sequel::Database) }
      attr_reader :db

      sig do
        params(api: ApiClient, db: Sequel::Database, sim_url: String, acquirer_url: String,
               clock: Clearinghouse::Clock).void
      end
      def initialize(api:, db:, sim_url:, acquirer_url:, clock:)
        @api = api
        @db = db
        @sim_url = sim_url
        @acquirer_url = acquirer_url
        @clock = clock
      end

      # A confirmed automatic-capture payment of DISPUTED_AMOUNT. Returns its id.
      sig { params(tag: String, payment_method: String).returns(String) }
      def payment(tag, payment_method)
        created = @api.post('/v1/payment_intents', CREATE_PARAMS.merge('payment_method' => payment_method),
                            key: "#{tag}:setup-create")
        raise Scenario::SetupError, "setup create: #{created}" unless created.status == 200

        id = created.json.fetch('id')
        confirmed = @api.post("/v1/payment_intents/#{id}/confirm", {}, key: "#{tag}:setup-confirm")
        raise Scenario::SetupError, "setup confirm: #{confirmed}" unless confirmed.status == 200 &&
                                                                         confirmed.json['status'] == 'succeeded'

        id
      end

      # The availability sweep, on a clock past the payout delay.
      sig { void }
      def release_funds!
        later = Clearinghouse::Clock::Test.new(start: Clearinghouse::Clock::Real.new.now +
                                                      (3 * Clearinghouse::Clock::SECONDS_PER_DAY))
        Clearinghouse::Balances::Availability.release_due!(@db, clock: later)
      end

      # A payout through the API. Returns its id.
      sig { params(tag: String, amount: Integer).returns(String) }
      def payout(tag, amount)
        reply = @api.post('/v1/payouts', { 'amount' => amount, 'currency' => 'usd' }, key: "#{tag}:setup-payout")
        raise Scenario::SetupError, "setup payout: #{reply}" unless reply.status == 200

        reply.json.fetch('id')
      end

      # One poll in this process, unarmed, on the poller's clock. Setups use it to
      # get past notifications that are not the one under test.
      sig { returns(Clearinghouse::Acquirer::NotificationPoller::Result) }
      def poll!
        Clearinghouse::Acquirer::NotificationPoller.new(
          db: @db, client: Clearinghouse::Acquirer::Client.new(clock: @clock, base_url: @acquirer_url),
          clock: @clock, handlers: Clearinghouse::Settlement.notification_handlers(clock: @clock)
        ).poll
      end

      # The acquirer rules on the dispute over `intent_id`'s payment, through the
      # simulator's admin endpoint, at the poller's time.
      sig { params(intent_id: String, outcome: String).void }
      def resolve_dispute(intent_id, outcome)
        reference = @db[:payment_intents].where(id: intent_id).get(:acquirer_reference)
        dispute = sim_get('/admin/operations').fetch('disputes').find { |d| d['acquirer_reference'] == reference }
        raise Scenario::SetupError, "no dispute at the acquirer for #{intent_id}" unless dispute

        request = Net::HTTP::Post.new("/admin/disputes/#{dispute.fetch('id')}/resolve")
        request['Content-Type'] = 'application/json'
        request['Sim-Time'] = @clock.now.utc.iso8601(6)
        request.body = JSON.generate('outcome' => outcome)
        response = sim(request)
        raise Scenario::SetupError, "resolve: #{response.code} #{response.body}" unless response.code == '200'
      end

      # Every notification due on the poller's clock, in feed order.
      sig { returns(T::Array[Clearinghouse::Acquirer::Notification]) }
      def feed
        client = Clearinghouse::Acquirer::Client.new(clock: @clock, base_url: @sim_url)
        all = []
        cursor = '0'
        loop do
          page = client.notifications(after: cursor)
          if page.is_a?(Clearinghouse::Acquirer::Unavailable)
            raise "the simulator's feed is unavailable: #{page.reason}"
          end

          break if page.data.empty?

          all.concat(page.data)
          cursor = page.next_cursor
        end
        all
      end

      private

      sig { params(path: String).returns(T::Hash[String, T.untyped]) }
      def sim_get(path)
        JSON.parse(sim(Net::HTTP::Get.new(path)).body.to_s)
      end

      sig { params(request: Net::HTTPRequest).returns(Net::HTTPResponse) }
      def sim(request)
        uri = URI.parse(@sim_url)
        Net::HTTP.start(T.must(uri.host), uri.port, open_timeout: 5, read_timeout: 30) { |h| h.request(request) }
      end
    end

    # The world one background case needs, per notification type. There is one
    # per type Settlement.notification_handlers registers; a type without one is
    # still planned and its cases fail with MissingScenarioError.
    class BackgroundScenario
      extend T::Sig
      extend T::Helpers

      abstract!

      sig { abstract.returns(String) }
      def flow; end

      # Makes exactly one notification of this flow's type due and unprocessed,
      # with everything before it in the feed already processed. Returns what
      # `subject` needs.
      sig { abstract.params(world: BackgroundWorld, tag: String).returns(T::Hash[String, String]) }
      def setup(world, tag); end

      # The id of the object the notification changes (a dp_ or a po_), nil if it
      # does not exist.
      sig { abstract.params(db: Sequel::Database, state: T::Hash[String, String]).returns(T.nilable(String)) }
      def subject(db, state); end

      # The event types the subject must have, in order, once the poll is done.
      sig { abstract.returns(T::Array[String]) }
      def expected_events; end

      # What the object must look like once the notification is applied.
      sig { abstract.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts); end

      private

      sig { params(facts: T::Hash[String, T.untyped], expected: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def expect_object(facts, expected)
        got = facts.fetch('object').slice(*expected.keys)
        got == expected ? [] : ["#{facts.dig('object', 'object')} is #{got}, expected #{expected}"]
      end
    end

    # dispute.opened: a pm_card_disputeFraudulent payment, its funds released,
    # and the clock past the day the acquirer opens the dispute.
    class DisputeOpenedScenario < BackgroundScenario
      sig { override.returns(String) }
      def flow = Clearinghouse::Acquirer::NotificationPoller.flow_name('dispute.opened')

      sig { override.params(world: BackgroundWorld, tag: String).returns(T::Hash[String, String]) }
      def setup(world, tag)
        intent = world.payment(tag, 'pm_card_disputeFraudulent')
        world.release_funds!
        { 'intent_id' => intent }
      end

      sig { override.params(db: Sequel::Database, state: T::Hash[String, String]).returns(T.nilable(String)) }
      def subject(db, state)
        ids = db[:disputes].where(payment_intent: state.fetch('intent_id')).select_map(:id)
        ids.length == 1 ? ids.first : nil
      end

      sig { override.returns(T::Array[String]) }
      def expected_events = ['charge.dispute.created']

      sig { override.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts)
        expect_object(facts, 'status' => 'needs_response', 'amount' => DISPUTED_AMOUNT, 'fee' => DISPUTE_FEE,
                             'closed_by' => nil)
      end
    end

    # dispute.closed, won: the dispute already opened (the harness polled it in),
    # then the acquirer rules for the merchant.
    class DisputeClosedScenario < DisputeOpenedScenario
      sig { override.returns(String) }
      def flow = Clearinghouse::Acquirer::NotificationPoller.flow_name('dispute.closed')

      sig { override.params(world: BackgroundWorld, tag: String).returns(T::Hash[String, String]) }
      def setup(world, tag)
        state = super
        opened = world.poll!
        raise Scenario::SetupError, "setup poll: #{opened.serialize}" unless opened.processed == 1

        world.resolve_dispute(state.fetch('intent_id'), 'won')
        state
      end

      sig { override.returns(T::Array[String]) }
      def expected_events = %w[charge.dispute.created charge.dispute.closed]

      sig { override.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts)
        expect_object(facts, 'status' => 'won', 'amount' => DISPUTED_AMOUNT, 'fee' => DISPUTE_FEE,
                             'closed_by' => 'acquirer')
      end
    end

    # payout.paid or payout.failed: a funded balance and a payout the bank has
    # answered. The simulator fails a payout whose amount ends in 13.
    class PayoutAnsweredScenario < BackgroundScenario
      abstract!

      sig { abstract.returns(Integer) }
      def amount; end

      sig { abstract.returns(String) }
      def answer; end

      sig { override.returns(String) }
      def flow = Clearinghouse::Acquirer::NotificationPoller.flow_name("payout.#{answer}")

      sig { override.params(world: BackgroundWorld, tag: String).returns(T::Hash[String, String]) }
      def setup(world, tag)
        world.payment(tag, 'pm_card_visa')
        world.release_funds!
        { 'payout_id' => world.payout(tag, amount) }
      end

      sig { override.params(db: Sequel::Database, state: T::Hash[String, String]).returns(T.nilable(String)) }
      def subject(db, state)
        db[:payouts].where(id: state.fetch('payout_id')).get(:id)
      end

      sig { override.returns(T::Array[String]) }
      def expected_events = ['payout.created', "payout.#{answer}"]

      sig { override.params(facts: T::Hash[String, T.untyped]).returns(T::Array[String]) }
      def resting_problems(facts)
        expect_object(facts, 'status' => answer, 'amount' => amount)
      end
    end

    # payout.paid.
    class PayoutPaidScenario < PayoutAnsweredScenario
      sig { override.returns(Integer) }
      def amount = 1000

      sig { override.returns(String) }
      def answer = 'paid'
    end

    # payout.failed, by the simulator's rule on the amount.
    class PayoutFailedScenario < PayoutAnsweredScenario
      sig { override.returns(Integer) }
      def amount = 1013

      sig { override.returns(String) }
      def answer = 'failed'
    end

    BACKGROUND_SCENARIOS = T.let(
      [DisputeOpenedScenario.new, DisputeClosedScenario.new, PayoutPaidScenario.new, PayoutFailedScenario.new]
        .to_h { |s| [s.flow, s] }.freeze,
      T::Hash[String, BackgroundScenario]
    )

    sig { params(flow: String).returns(BackgroundScenario) }
    def self.background_scenario_for(flow)
      BACKGROUND_SCENARIOS.fetch(flow) do
        raise MissingScenarioError,
              "background flow #{flow} is registered but has no crash-matrix scenario; add one in " \
              'sim/experiments/crash_matrix/background.rb so its recovery points are tested'
      end
    end

    # Reads what the poller's work left: the feed's bookkeeping and the object a
    # notification changed.
    class BackgroundInspector
      extend T::Sig

      sig { params(db: Sequel::Database).void }
      def initialize(db:)
        @db = db
      end

      # Everything a poll can change, normalised. Two snapshots are equal when the
      # same work is durable.
      sig { returns(T::Hash[String, T.untyped]) }
      def snapshot
        Normalize.call({
                         'cursor' => cursor, 'processed' => processed.map { |r| r[:type] },
                         'disputes' => @db[:disputes].order(:created_at, :id).select_map(%i[status closed_by]),
                         'payouts' => @db[:payouts].order(:created_at, :id).select_map(%i[status recovery_point]),
                         'events' => @db[:events].order(:seq).select_map(:type),
                         'ledger' => @db[:ledger_transactions].order(:id).select_map(%i[flow_type description])
                       })
      end

      # The poller's stored cursor. A poller inserts "0" (the start of the feed)
      # before it reads anything, so no row and "0" mean the same.
      sig { returns(String) }
      def cursor = @db[:acquirer_cursors].where(name: 'acquirer').get(:cursor) || '0'

      # processed_notifications in feed order.
      sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def processed
        @db[:processed_notifications].all.sort_by { |r| Integer(r.fetch(:cursor)) }
      end

      # Everything about one dispute or payout: its row, its events with their
      # payloads, its ledger transactions with amounts, and the notifications
      # applied to it. Normalised, so the crashed run's can be compared with the
      # control's.
      sig { params(subject: String).returns(T::Hash[String, T.untyped]) }
      def facts(subject)
        row = @db[:disputes].where(id: subject).first || @db[:payouts].where(id: subject).first || {}
        needles = [subject, row[:acquirer_reference]].compact
        Normalize.call(
          'object' => object_state(subject, row),
          'events' => @db[:events].where(object_id: subject).order(:seq).map do |e|
            { 'type' => e[:type], 'data' => Clearinghouse::DB.from_json(e[:data]) }
          end,
          'ledger' => @db.fetch(<<~SQL, subject).map { |r| r.transform_keys(&:to_s) },
            SELECT t.flow_type, t.description, sum(e.amount) FILTER (WHERE e.side = 'D')::bigint AS amount
              FROM ledger_transactions t JOIN ledger_entries e ON e.transaction_id = t.id
             WHERE t.flow_id = ? GROUP BY t.id ORDER BY t.id
          SQL
          'notifications' => processed.select { |r| needles.any? { |n| JSON.generate(r[:data]).include?(n) } }
                                      .map { |r| { 'type' => r[:type], 'data' => untimed(r[:data]) } }
        )
      end

      # Each due notification applied once, nothing else applied, the cursor on
      # the last one, and no object with the same event twice.
      sig { params(feed: T::Array[Clearinghouse::Acquirer::Notification]).returns(T::Array[String]) }
      def exactly_once_problems(feed)
        rows = processed
        problems = []
        applied = rows.map { |r| r[:id] }
        due = feed.map(&:id)
        problems << "processed #{applied}, the feed has #{due}" unless applied == due
        doubled = @db[:events].group_and_count(:object_id, :type).all.select { |r| r[:count] > 1 }
                              .map { |r| [r[:object_id], r[:type]] }
        problems << "events emitted twice: #{doubled}" unless doubled.empty?
        problems
      end

      # platform:dispute_clearing holds exactly the disputes not won: nothing has
      # settled in this experiment, so a lost or open dispute's amount is still
      # there and a won one's went back to the merchant.
      sig { returns(T::Array[String]) }
      def dispute_clearing_problems
        held = Clearinghouse::Ledger.balance(@db, Clearinghouse::Ledger::Flows::DISPUTE_CLEARING, 'usd').amount
        expected = @db[:disputes].exclude(status: 'won').sum(:amount).to_i
        held == expected ? [] : ["dispute_clearing holds #{held}, the disputes not won total #{expected}"]
      end

      private

      sig { params(subject: String, row: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def object_state(subject, row)
        return {} if row.empty?

        if subject.start_with?('dp_')
          row.slice(:status, :amount, :fee, :reason, :closed_by).transform_keys(&:to_s).merge('object' => 'dispute')
        else
          row.slice(:status, :amount, :recovery_point, :failure_code).transform_keys(&:to_s).merge('object' => 'payout')
        end
      end

      # Notification data without its timestamps, which differ between the two runs.
      sig { params(data: T.untyped).returns(T.untyped) }
      def untimed(data)
        parsed = data.is_a?(String) ? JSON.parse(data) : data.to_h
        parsed.reject { |k, _| k.to_s.end_with?('_at') }
      end
    end

    # Runs a background case against the same long-lived simulator, proxy and
    # database as the request cases, with a real bin/poller per poll.
    class BackgroundRunner < CaseRunner
      POLLER_DEADLINE = 60.0

      sig do
        params(settings: Settings, sim_url: String, proxy: RecordingProxy, riskgate_url: String,
               db: Sequel::Database, owner_db: Sequel::Database).void
      end
      def initialize(settings:, sim_url:, proxy:, riskgate_url:, db:, owner_db:)
        super
        @sim_url = sim_url
        @background = T.let(BackgroundInspector.new(db: db), BackgroundInspector)
        @poller_clock = T.let(Clearinghouse::Clock::Ahead.new(POLLER_AHEAD_S), Clearinghouse::Clock)
      end

      sig { params(kase: Case, index: Integer).returns(CaseResult) }
      def run(kase, index)
        result = CaseResult.new(kase: kase)
        started = CrashMatrix.monotonic
        begin
          scenario = CrashMatrix.background_scenario_for(kase.flow)
          tag = format('b%<i>03d', i: index)
          merchant = fresh_world
          api = start_api(nil, result, 'boot_api_s', "#{tag}-api")
          world = BackgroundWorld.new(api: api, db: @db, sim_url: @sim_url, acquirer_url: @proxy.url,
                                      clock: @poller_clock)
          state = timed(result, 'setup_s') { scenario.setup(world, tag) }
          crash_poller(kase, result, tag)
          recover_poller(kase, result, tag, world)
          control_state = timed(result, 'control_s') do
            control = scenario.setup(world, "#{tag}x")
            status, log = poll_process(nil, "#{tag}-poller-control", result, 'control')
            result.check('control_polled', [status, log['processed']] == [0, 1],
                         "control poller exit #{status}, #{log}")
            control
          end
          verify_background(scenario, result, world, merchant, [state, control_state])
        rescue StandardError => e
          result.error = "#{e.class}: #{e.message}"
        ensure
          @server&.stop
          @server = nil
          result.timings['total_s'] = CrashMatrix.seconds_since(started)
        end
        result
      end

      private

      # The armed poller: it must die with the crash status, and leave either
      # nothing (before the commit) or exactly the one notification (after it).
      sig { params(kase: Case, result: CaseResult, tag: String).void }
      def crash_poller(kase, result, tag)
        baseline = result.baseline_snapshot = @background.snapshot
        before = @background.processed.length
        status, = poll_process(kase.crash_name, "#{tag}-poller-armed", result, 'crashed_poll')
        result.check('crashed', status == Clearinghouse::Idempotency::CrashHook::CRASH_STATUS,
                     "bin/poller exit status #{status.inspect}")
        at_crash = result.crash_snapshot = @background.snapshot
        if kase.point == 'committed'
          rows = @background.processed
          ok = rows.length == before + 1 && @background.cursor == rows.last&.fetch(:cursor)
          result.check('state_at_crash', ok, "#{rows.length - before} notifications committed, cursor " \
                                             "#{@background.cursor.inspect}; expected one, cursor on it")
        else
          result.check('state_at_crash', at_crash == baseline,
                       "at the crash #{at_crash}; before the poll #{baseline}")
        end
      end

      # A clean poller finishes the job, then the harness polls once more.
      sig { params(kase: Case, result: CaseResult, tag: String, world: BackgroundWorld).void }
      def recover_poller(kase, result, tag, world)
        status, log = poll_process(nil, "#{tag}-poller-clean", result, 'recovery_poll')
        expected = kase.point == 'committed' ? 0 : 1
        result.recovery << "bin/poller --once: exit #{status}, #{log}"
        result.check('poller_recovered', [status, log['processed']] == [0, expected],
                     "exit #{status}, #{log}; expected processed #{expected}")
        before = @background.snapshot
        again = world.poll!
        result.recovery << "poll again: #{again.serialize}"
        result.check('second_poll_changes_nothing',
                     again.processed.zero? && again.already_processed.zero? && @background.snapshot == before,
                     "second poll: #{again.serialize}")
      end

      sig do
        params(scenario: BackgroundScenario, result: CaseResult, world: BackgroundWorld, merchant_id: String,
               states: [T::Hash[String, String], T::Hash[String, String]]).void
      end
      def verify_background(scenario, result, world, merchant_id, states)
        state, control_state = states
        subject = scenario.subject(@db, state)
        control_subject = scenario.subject(@db, control_state)
        raise "no object to check (#{state}, control #{control_state})" unless subject && control_subject

        facts = @background.facts(subject)
        control_facts = @background.facts(control_subject)
        feed = world.feed
        record_check(result, 'resting_state', scenario.resting_problems(facts))
        record_check(result, 'ledger_invariants', @inspector.ledger_problems)
        record_check(result, 'acquirer_equals_ledger',
                     @inspector.money_problems(merchant_id, @inspector.acquirer_books))
        events = facts.fetch('events').map { |e| e['type'] }
        record_check(result, 'exactly_once', @background.exactly_once_problems(feed) +
          (events == scenario.expected_events ? [] : ["events #{events}, expected #{scenario.expected_events}"]))
        result.check('cursor_at_end', @background.cursor == feed.last&.cursor,
                     "cursor #{@background.cursor.inspect}, last in the feed #{feed.last&.cursor.inspect}")
        record_check(result, 'dispute_clearing', @background.dispute_clearing_problems)
        result.check('same_outcome_as_control', facts == control_facts,
                     "crashed #{JSON.generate(facts)[0, 800]} vs control #{JSON.generate(control_facts)[0, 800]}")
      end

      sig { params(result: CaseResult, name: String, problems: T::Array[String]).void }
      def record_check(result, name, problems)
        result.check(name, problems.empty?, problems.join('; '))
      end

      # One `bin/poller --once`, armed at `crash_at` or not, on the poller's
      # clock. Returns its exit status and its last log line.
      sig do
        params(crash_at: T.nilable(String), log_name: String, result: CaseResult, exchange: String)
          .returns([T.nilable(Integer), T::Hash[String, T.untyped]])
      end
      def poll_process(crash_at, log_name, result, exchange)
        log = File.join(@settings.log_dir, "#{log_name}.log")
        env = base_env.merge('CLEARINGHOUSE_CRASH_AT' => crash_at.to_s,
                             'CLEARINGHOUSE_CLOCK_AHEAD_S' => POLLER_AHEAD_S.to_s)
        mark = @proxy.mark
        started = CrashMatrix.monotonic
        pid = T.unsafe(Process).spawn(env, RbConfig.ruby, '-rbundler/setup', File.join(Processes::ROOT, 'bin/poller'),
                                      '--once', chdir: Processes::ROOT, out: [log, 'w'], err: [log, 'a'])
        status = wait_for_poller(pid)
        result.timings["#{exchange}_s"] = CrashMatrix.seconds_since(started)
        result.exchanges[exchange] = @proxy.since(mark).map(&:to_s)
        [status, last_json(log)]
      end

      sig { params(pid: Integer).returns(T.nilable(Integer)) }
      def wait_for_poller(pid)
        deadline = CrashMatrix.monotonic + POLLER_DEADLINE
        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return status.exitstatus if status

          if CrashMatrix.monotonic > deadline
            Process.kill('KILL', pid)
            Process.waitpid2(pid)
            return nil
          end

          sleep 0.05
        end
      end

      sig { params(log: String).returns(T::Hash[String, T.untyped]) }
      def last_json(log)
        line = File.readlines(log).reverse.find { |l| l.start_with?('{') }
        line ? JSON.parse(line) : {}
      rescue Errno::ENOENT, JSON::ParserError
        {}
      end
    end
  end
end
