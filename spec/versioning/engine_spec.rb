# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Versioning::Engine do
  subject(:engine) { Clearinghouse::Versioning.engine }

  let(:intent) { fixture('payment_intent') }
  let(:declined) { fixture('payment_intent_declined') }

  describe 'the shipped registry' do
    it 'has the initial version and one version per change date, oldest first' do
      expect(engine.versions).to eq(%w[2026-01-01 2026-03-01 2026-06-01 2026-09-01])
      expect(engine.latest).to eq('2026-09-01')
    end
  end

  describe '2026-03-01 amount_received rename' do
    it 'renders amount_captured, in the same position, for older callers' do
      old = engine.render(intent, '2026-01-01')
      expect(old).not_to have_key('amount_received')
      expect(old['amount_captured']).to eq(2000)
      expect(old.keys.index('amount_captured')).to eq(intent.keys.index('amount_received'))
    end

    it 'leaves callers on or after the change alone' do
      expect(engine.render(intent, '2026-03-01')['amount_received']).to eq(2000)
    end
  end

  describe '2026-06-01 last_payment_error object' do
    it 'flattens the object into failure_code and failure_message and drops decline_code' do
      old = engine.render(declined, '2026-03-01')
      expect(old).not_to have_key('last_payment_error')
      expect(old).to include('failure_code' => 'card_declined',
                             'failure_message' => 'Your card has insufficient funds.')
      expect(old.to_s).not_to include('insufficient_funds"')
    end

    it 'renders a null error as two nulls' do
      expect(engine.render(intent, '2026-03-01')).to include('failure_code' => nil, 'failure_message' => nil)
    end

    it 'keeps the object for 2026-06-01 callers' do
      expect(engine.render(declined, '2026-06-01')['last_payment_error']['decline_code']).to eq('insufficient_funds')
    end
  end

  describe '2026-09-01 expandable payment_method' do
    it 'renders the id at the latest version' do
      expect(engine.render(intent, '2026-09-01')['payment_method']).to eq('pm_card_visa')
    end

    it 'embeds the object for older callers without being asked' do
      expect(engine.render(intent, '2026-06-01')['payment_method']).to eq(
        'id' => 'pm_card_visa', 'object' => 'payment_method', 'type' => 'card',
        'card' => { 'brand' => 'visa', 'last4' => '4242' }
      )
    end

    it 'embeds the object at the latest version when the caller expands it' do
      expect(engine.render(intent, '2026-09-01', expand: ['payment_method'])['payment_method']['card']['last4'])
        .to eq('4242')
    end

    it 'leaves a null payment_method null' do
      expect(engine.render(declined, '2026-01-01')['payment_method']).to be_nil
    end

    it 'fails loudly if the loader finds nothing, rather than rendering a bare id to an old caller' do
      intent['payment_method'] = 'pm_card_unknown'
      expect { engine.render(intent, '2026-06-01') }
        .to raise_error(Clearinghouse::Versioning::Expander::MissingObjectError)
    end

    it 'guards against a transform running on an unexpanded id' do
      change_class = Clearinghouse::Versioning::Changes::ExpandablePaymentMethod
      expect { change_class.new.transform(intent) }.to raise_error(change_class::NotExpandedError)
    end
  end

  describe 'walking the tree' do
    it 'transforms payment_intents inside a list' do
      list = engine.render(fixture('payment_intent_list'), '2026-01-01')
      expect(list['data'].map { |pi| pi['amount_captured'] }).to eq([2000, 0])
      expect(list['data'].first['payment_method']).to be_a(Hash)
    end

    it 'transforms the payment_intent inside an event and stamps the version' do
      event = engine.render_event(fixture('event_payment_intent_succeeded'), '2026-03-01')
      expect(event['api_version']).to eq('2026-03-01')
      expect(event['data']['object']).to include('amount_received' => 2000, 'failure_code' => nil)
      expect(event['data']['object']['payment_method']).to be_a(Hash)
    end

    it 'transforms a payment_intent embedded in another object' do
      refund = { 'id' => 're_1', 'object' => 'refund', 'amount' => 500, 'payment_intent' => intent }
      old = engine.render(refund, '2026-01-01')
      expect(old['payment_intent']).to include('amount_captured' => 2000)
      expect(old['payment_intent']).not_to have_key('amount_received')
    end

    it 'never rewrites metadata, even when it looks like an object' do
      intent['metadata'] = { 'object' => 'payment_intent', 'amount_received' => '5', 'last_payment_error' => 'x' }
      expect(engine.render(intent, '2026-01-01')['metadata']).to eq(intent['metadata'])
    end

    it 'does not modify the object it was given' do
      before = Marshal.load(Marshal.dump(intent))
      engine.render(intent, '2026-01-01')
      expect(intent).to eq(before)
    end

    it 'refuses an unknown version' do
      expect { engine.render(intent, '2025-12-31') }.to raise_error(described_class::UnknownVersionError)
    end
  end

  describe 'protected fields' do
    def paths(node, prefix = [], out = {})
      case node
      when Hash
        node.each do |key, value|
          next if key == 'metadata'

          out[prefix + [key]] = value if described_class::PROTECTED_FIELDS.include?(key) && !value.is_a?(Hash)
          paths(value, prefix + [key], out)
        end
      when Array then node.each_with_index { |value, i| paths(value, prefix + [i], out) }
      end
      out
    end

    it 'leaves every protected field unchanged at every version for every fixture' do
      Dir[File.join(VersioningSpecHelpers::FIXTURES, '*.json')].each do |file|
        latest = JSON.parse(File.read(file))
        engine.versions.each do |version|
          rendered = latest['object'] == 'event' ? engine.render_event(latest, version) : engine.render(latest, version)
          rendered_paths = paths(rendered)
          paths(latest).each { |path, value| expect(rendered_paths[path]).to eq(value), "#{file} #{version} #{path}" }
        end
      end
    end

    it 'rejects a change that alters one' do
      rogue = build_change(version: '2026-02-01') { |o| o.merge('status' => 'complete') }
      rogue_engine = described_class.new(
        registry: Clearinghouse::Versioning::Registry.new(initial: '2026-01-01', changes: [rogue]),
        expander: Clearinghouse::Versioning::Expander.new
      )
      expect { rogue_engine.render(intent, '2026-01-01') }.to raise_error(described_class::ProtectedFieldError)
    end

    it 'rejects a change that drops one' do
      rogue = build_change(version: '2026-02-01') { |o| o.except('currency') }
      rogue_engine = described_class.new(
        registry: Clearinghouse::Versioning::Registry.new(initial: '2026-01-01', changes: [rogue]),
        expander: Clearinghouse::Versioning::Expander.new
      )
      expect { rogue_engine.render(intent, '2026-01-01') }.to raise_error(described_class::ProtectedFieldError)
    end
  end

  describe 'expand paths' do
    let(:charge_engine) do
      expander = Clearinghouse::Versioning.default_expander
      expander.register('payment_intent', 'latest_charge') do |id, _ctx|
        { 'id' => id, 'object' => 'charge', 'balance_transaction' => 'txn_1' }
      end
      expander.register('charge', 'balance_transaction') do |id, ctx|
        { 'id' => id, 'object' => 'balance_transaction', 'ctx' => ctx }
      end
      described_class.new(registry: Clearinghouse::Versioning.registry, expander: expander)
    end

    it 'expands through an expandable field, passing the context to each loader' do
      out = charge_engine.render(intent, '2026-09-01', expand: ['latest_charge.balance_transaction'], context: :ctx)
      expect(out['latest_charge']['balance_transaction']).to eq('id' => 'txn_1', 'object' => 'balance_transaction',
                                                                'ctx' => :ctx)
    end

    it 'expands inside a list through data' do
      out = engine.render(fixture('payment_intent_list'), '2026-09-01', expand: ['data.payment_method'])
      expect(out['data'].map { |pi| pi['payment_method'] && pi['payment_method']['id'] }).to eq(['pm_card_visa', nil])
    end

    it 'rejects a field that does not exist' do
      expect { engine.render(intent, '2026-09-01', expand: ['nope']) }
        .to raise_error(described_class::InvalidExpansionError, 'nope')
    end

    it 'rejects a field that exists but cannot be expanded' do
      expect { engine.render(intent, '2026-09-01', expand: ['customer_email']) }
        .to raise_error(described_class::InvalidExpansionError)
    end
  end

  describe 'request transforms' do
    let(:rename) do
      Class.new(Clearinghouse::Versioning::VersionChange) do
        def version = '2026-02-01'
        def description = 'capture takes amount_to_capture instead of amount'
        def resources = ['payment_intent']
        def transform(object) = object
        def request_endpoints = ['payment_intents.capture']

        def transform_request(_endpoint, params)
          Clearinghouse::Versioning::VersionChange.rename_key(params, 'amount', 'amount_to_capture')
        end
      end.new
    end
    let(:later) do
      Class.new(Clearinghouse::Versioning::VersionChange) do
        def version = '2026-04-01'
        def description = 'amount_to_capture must be a string'
        def resources = ['payment_intent']
        def transform(object) = object
        def request_endpoints = ['payment_intents.capture']
        def transform_request(_endpoint, params) = params.merge('seen' => params.keys)
      end.new
    end
    let(:req_engine) do
      registry = Clearinghouse::Versioning::Registry.new(initial: '2026-01-01', changes: [later, rename])
      described_class.new(registry: registry, expander: Clearinghouse::Versioning::Expander.new)
    end

    it 'rewrites old parameter names into the latest shape, oldest change first' do
      out = req_engine.transform_request('payment_intents.capture', { 'amount' => 500 }, '2026-01-01')
      expect(out).to eq('amount_to_capture' => 500, 'seen' => ['amount_to_capture'])
    end

    it 'skips changes the caller has already seen' do
      out = req_engine.transform_request('payment_intents.capture', { 'amount_to_capture' => 500 }, '2026-02-01')
      expect(out).to eq('amount_to_capture' => 500, 'seen' => ['amount_to_capture'])
    end

    it 'only touches the endpoints a change names' do
      expect(req_engine.transform_request('payment_intents.create', { 'amount' => 5 },
                                          '2026-01-01')).to eq('amount' => 5)
    end
  end

  describe '#legacy?' do
    it 'is true for callers from before the change and false from its version on' do
      change = Clearinghouse::Versioning::Changes::LastPaymentErrorObject
      expect(engine.legacy?(change, '2026-03-01')).to be(true)
      expect(engine.legacy?(change, '2026-06-01')).to be(false)
      expect(engine.legacy?(change, '2026-09-01')).to be(false)
    end
  end
end
