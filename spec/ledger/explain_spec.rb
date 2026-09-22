# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Ledger::Explain, :db,
               mutant_expression: %w[Clearinghouse::Ledger::Explain Clearinghouse::Ledger.explain] do
  let(:receivable) { 'platform:processor_receivable' }

  def payment(flow_id = 'pi_1', settle_gross: 10_000)
    flow_event(flow_id, :capture, day: 0, merchant_id: 'm1', gross: money(10_000), fee: money(320))
    flow_event(flow_id, :settlement, day: 2, gross: money(settle_gross), acquirer_fee: money(160))
    flow_event(flow_id, :funds_available, day: 2, merchant_id: 'm1', net: money(9680))
  end

  def render(flow_id, color: false)
    Clearinghouse::Ledger::ExplainPrinter.render(Clearinghouse::Ledger.explain(app_db, flow_id), color: color)
  end

  describe '.run' do
    it 'traces every transaction and entry in order with the running clearing state' do
      payment
      explanation = Clearinghouse::Ledger.explain(app_db, 'pi_1')
      expect([explanation.flow_id, explanation.flow_type]).to eq(%w[pi_1 payment])
      expect(explanation.steps.map(&:description)).to eq(['capture', 'settlement', 'funds available'])
      expect(explanation.steps.map(&:clearing_after))
        .to eq([{ [receivable, 'usd'] => 10_000 }, { [receivable, 'usd'] => 0 }, { [receivable, 'usd'] => 0 }])
      capture = explanation.steps.first
      lines = capture.lines.map { |l| [l.account, l.kind, l.side, l.amount] }
      expect(lines).to eq([[receivable, :clearing, :debit, money(10_000)],
                           ['merchant:m1:pending', :liability, :credit, money(9680)],
                           ['platform:fee_revenue', :revenue, :credit, money(320)]])
      expect(capture.effective_at).to eq(LedgerHelpers::T0)
      expect(explanation).to be_explained
    end

    it 'says a flow is not explained while money sits in clearing' do
      payment(settle_gross: 9900)
      explanation = Clearinghouse::Ledger.explain(app_db, 'pi_1')
      expect(explanation).not_to be_explained
      expect(explanation.clearing).to eq([receivable, 'usd'] => 100)
    end

    it 'links reversals in both directions' do
      payment
      reversed = app_db[:ledger_transactions].where(description: 'funds available').get(:id)
      reversal = Clearinghouse::Ledger.reverse!(app_db, reversed, reason: 'too early', effective_at: LedgerHelpers::T0)
      steps = Clearinghouse::Ledger.explain(app_db, 'pi_1').steps.to_h { |s| [s.transaction_id, s] }
      expect(steps.fetch(reversed).reversed_by).to eq(reversal)
      expect(steps.fetch(reversal).reverses_transaction_id).to eq(reversed)
    end

    it 'refuses a flow with no transactions' do
      expect { Clearinghouse::Ledger.explain(app_db, 'pi_none') }
        .to raise_error(described_class::FlowNotFoundError, 'no ledger transactions for flow "pi_none"')
    end

    it 'treats an explanation with no steps as touching no clearing account' do
      empty = described_class::Explanation.new(flow_id: 'pi_1', flow_type: 'payment', steps: [])
      expect(empty.clearing).to eq({})
      expect(empty).to be_explained
    end
  end

  # Nested under Explain, so without the tag mutant would not pick these for the printer.
  describe Clearinghouse::Ledger::ExplainPrinter, mutant_expression: 'Clearinghouse::Ledger::ExplainPrinter' do
    it 'renders a payment as a table with a running clearing column' do
      payment
      expect(render('pi_1')).to eq(<<~TEXT)
        Flow pi_1 · payment · 3 transactions · EXPLAINED

        ┌─────┬─────────────────────┬─────────────────────────────────┬────────────┬────────────┬──────────────────────┐
        │ txn │ effective (UTC)     │ transaction / account           │      debit │     credit │ processor_receivable │
        ├─────┼─────────────────────┼─────────────────────────────────┼────────────┼────────────┼──────────────────────┤
        │ #1  │ 2026-01-01 00:00:00 │ capture                         │            │            │           100.00 USD │
        │     │                     │   platform:processor_receivable │ 100.00 USD │            │                      │
        │     │                     │   merchant:m1:pending           │            │  96.80 USD │                      │
        │     │                     │   platform:fee_revenue          │            │   3.20 USD │                      │
        ├─────┼─────────────────────┼─────────────────────────────────┼────────────┼────────────┼──────────────────────┤
        │ #2  │ 2026-01-03 00:00:00 │ settlement                      │            │            │             0.00 USD │
        │     │                     │   platform:cash                 │  98.40 USD │            │                      │
        │     │                     │   platform:processing_expense   │   1.60 USD │            │                      │
        │     │                     │   platform:processor_receivable │            │ 100.00 USD │                      │
        ├─────┼─────────────────────┼─────────────────────────────────┼────────────┼────────────┼──────────────────────┤
        │ #3  │ 2026-01-03 00:00:00 │ funds available                 │            │            │             0.00 USD │
        │     │                     │   merchant:m1:pending           │  96.80 USD │            │                      │
        │     │                     │   merchant:m1:available         │            │  96.80 USD │                      │
        └─────┴─────────────────────┴─────────────────────────────────┴────────────┴────────────┴──────────────────────┘

        Explained: every clearing account this flow touched is back at zero.
      TEXT
    end

    it 'names what is still sitting in clearing when a flow is not explained' do
      payment(settle_gross: 9900)
      text = render('pi_1')
      expect(text.lines.first).to eq("Flow pi_1 · payment · 3 transactions · NOT EXPLAINED\n")
      expect(text).to end_with("Not explained: money is still sitting in clearing.\n  " \
                               "platform:processor_receivable  1.00 USD\n")
    end

    it 'marks reversals and splits a clearing column by currency when a code appears in two' do
      payment
      flow_event('pi_1', :capture, day: 3, merchant_id: 'm1', gross: money(500, 'jpy'), fee: money(15, 'jpy'))
      first = app_db[:ledger_transactions].min(:id)
      Clearinghouse::Ledger.reverse!(app_db, first, reason: 'duplicate', effective_at: LedgerHelpers::T0)
      text = render('pi_1')
      expect(text).to include('processor_receivable USD', 'processor_receivable JPY', 'capture (reversed by #5)',
                              'reversal: duplicate (reverses #1)')
    end

    it 'says so when a flow never touched a clearing account' do
      flow_event('pi_1', :funds_available, day: 0, merchant_id: 'm1', net: money(100))
      text = render('pi_1')
      expect(text.lines.first).to eq("Flow pi_1 · payment · 1 transaction · EXPLAINED\n")
      expect(text).to end_with("Explained: this flow never touched a clearing account.\n")
    end

    # Four clearing accounts in one flow: three left open, one back at zero. The longest
    # open code is neither first nor last, so the verdict has to find the widest one.
    def mixed_flow
      post([debit('merchant:m1:available', money(50)), credit('platform:refund_clearing', money(50))], flow_id: 'pi_9')
      post([debit(receivable, money(100)), credit('merchant:m1:pending', money(100))], flow_id: 'pi_9')
      post([debit('merchant:m1:available', money(10)), credit('platform:dispute_clearing', money(10))], flow_id: 'pi_9')
      post([debit('platform:dispute_clearing', money(10)), credit('merchant:m1:available', money(10))], flow_id: 'pi_9')
      post([debit('merchant:m1:available', money(20)), credit('platform:payout_clearing', money(20))], flow_id: 'pi_9')
      Clearinghouse::Ledger.explain(app_db, 'pi_9')
    end

    it 'gives each clearing account its own column and lists only the open ones, aligned' do
      text = described_class.render(mixed_flow)
      header = text.lines[3]
      expect(header).to start_with('│ txn │ effective (UTC)     │ transaction / account           │')
      expect(header)
        .to end_with("│ refund_clearing │ processor_receivable │ dispute_clearing │ payout_clearing │\n")
      expect(text).to end_with(<<~TEXT)
        Not explained: money is still sitting in clearing.
          platform:refund_clearing       0.50 USD
          platform:processor_receivable  1.00 USD
          platform:payout_clearing       0.20 USD
      TEXT
    end

    it 'styles titles, headers and clearing cells when colored' do
      text = described_class.render(mixed_flow, color: true)
      expect(text).to include(
        "\e[1mFlow pi_9\e[0m", "│ \e[1mtxn\e[0m │",
        "│ \e[1m#1 \e[0m │ \e[2m2026-01-01 00:00:00\e[0m │ \e[1mtest",
        "\e[31m            1.00 USD\e[0m", "\e[32m        0.00 USD\e[0m",
        "\e[31mNot explained\e[0m: money is still sitting in clearing."
      )
    end

    it 'paints the explained verdicts green' do
      flow_event('pi_1', :funds_available, day: 0, merchant_id: 'm1', net: money(100))
      payment('pi_2')
      expect(render('pi_1', color: true))
        .to include("\e[32mExplained\e[0m: this flow never touched a clearing account.")
      expect(render('pi_2', color: true))
        .to include("\e[32mExplained\e[0m: every clearing account this flow touched is back at zero.")
    end

    it 'is plain text unless color is asked for' do
      payment
      explanation = Clearinghouse::Ledger.explain(app_db, 'pi_1')
      expect(described_class.render(explanation)).not_to include("\e[")
      expect(described_class.render_table(explanation)).not_to include("\e[")
    end

    it 'prints effective times in UTC, as the column header says, whatever zone the Time is in' do
      step = Clearinghouse::Ledger::Explain::Step.new(
        transaction_id: 1, description: 'capture', effective_at: Time.new(2026, 1, 1, 9, 0, 0, '+09:00'),
        reverses_transaction_id: nil, reversed_by: nil, lines: [], clearing_after: {}
      )
      explanation = Clearinghouse::Ledger::Explain::Explanation.new(flow_id: 'pi_1', flow_type: 'payment',
                                                                    steps: [step])
      expect(described_class.render_table(explanation)).to include('2026-01-01 00:00:00')
    end

    it 'colors open clearing red and cleared clearing green when asked' do
      payment('pi_1', settle_gross: 9900)
      payment('pi_2')
      expect(render('pi_1', color: true)).to include("\e[31mNOT EXPLAINED\e[0m", "\e[31m1.00 USD\e[0m")
      expect(render('pi_2', color: true)).to include("\e[32mEXPLAINED\e[0m", "\e[32m            0.00 USD\e[0m")
      expect(render('pi_1')).not_to include("\e[")
    end
  end
end
