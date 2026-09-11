# typed: false
# frozen_string_literal: true

RSpec.describe Clearinghouse::Idempotency::Runner, :db do
  include_context 'with the toy flow'

  let(:idem) { Clearinghouse::Idempotency }

  describe 'a new key' do
    it 'runs every phase once, stores the response, and lets the lease go' do
      result = run_toy(request_id: 'req_first')
      expect(result.replayed).to be(false)
      expect(result.response.status).to eq(200)
      expect(JSON.parse(result.response.body)).to eq('label' => 'a', 'state' => { 'written_at' => 'a' })
      expect(log_steps).to eq(%w[written called finished])
      row = key_row
      expect(row).to include(recovery_point: 'finished', locked_at: nil, lock_token: nil, response_code: 200,
                             response_body: result.response.body, client_supplied: true, flow: 'spec.toy',
                             request_method: 'POST', request_path: '/v1/toys', request_id: 'req_first')
      expect([JSON.parse(row[:flow_state]), JSON.parse(row[:render_options])])
        .to eq([{ 'written_at' => 'a' }, { 'style' => 'toy' }])
      expect([flow.resumed_seen, flow.released]).to eq([[false], [row[:id]]])
    end

    it 'records the fingerprint of method, path and params' do
      run_toy
      expect(key_row[:request_fingerprint])
        .to eq(idem::Fingerprint.compute(method: 'POST', path: '/v1/toys', params: { 'label' => 'a' }))
    end
  end

  describe 'the same key again' do
    it 'replays the stored response byte for byte and does nothing else' do
      first = run_toy(request_id: 'req_first')
      clock.advance(3600)
      again = run_toy
      expect([again.replayed, again.response, again.original_request_id]).to eq([true, first.response, 'req_first'])
      expect(log_steps).to eq(%w[written called finished])
      expect(flow.foreign_calls).to eq(['a'])
    end

    it 'refuses different parameters, before or after the first request finished' do
      run_toy(label: 'a')
      expect { run_toy(label: 'b') }.to raise_error(idem::KeyReusedError) { |e| expect(e.key).to eq('k1') }
      expect(log_steps.length).to eq(3)
    end

    it 'refuses while the first request holds the lease, without waiting or running anything' do
      seen = []
      flow.before_atomic = lambda { |step, _run|
        next unless step == 'called'

        seen << Thread.new do
          run_toy
          :ran
        rescue idem::KeyInUseError
          :in_use
        end.value
      }
      run_toy
      expect([seen, flow.foreign_calls]).to eq([[:in_use], ['a']])
    end

    it 'keeps the lease live for the lock timeout, then lets another request resume' do
      flow.fail_in['called'] = ToyFlow::TransientError.new('boom')
      expect { run_toy }.to raise_error(ToyFlow::TransientError)
      flow.fail_in.clear
      # The failed run gave its lease back, so a retry resumes at once.
      expect(key_row).to include(recovery_point: 'written', locked_at: nil)
      result = run_toy
      expect(result.replayed).to be(false)
      expect(log_steps).to eq(%w[written called finished])
      expect(flow.foreign_calls).to eq(%w[a a])
      expect(flow.resumed_seen).to eq([false, true])
    end
  end

  describe 'a stopped runner' do
    # What a crash leaves: a key at some recovery point, locked by a lease nobody renews.
    def abandon_at(point, locked_at: clock.now)
      run_toy
      app_db[:idempotency_keys].where(key: 'k1').update(recovery_point: point, locked_at: locked_at,
                                                        lock_token: 'dead', response_code: nil,
                                                        response_body: nil, response_headers: nil)
      app_db[:idem_spec_log].where(step: %w[called finished]).delete if point == 'written'
      app_db[:idem_spec_log].where(step: 'finished').delete if point == 'called'
    end

    it 'is in use until its lease expires, then is resumed from its recovery point' do
      abandon_at('written')
      clock.advance(59)
      expect { run_toy }.to raise_error(idem::KeyInUseError)
      clock.advance(2)
      expect(run_toy.response.status).to eq(200)
      expect(log_steps).to eq(%w[written called finished])
      expect(flow.resumed_seen).to eq([false, true])
    end

    it 'resumes by id for the completer, with the same rules' do
      abandon_at('called', locked_at: clock.now - 61)
      result = runner.resume(registry: registry, id: key_row[:id], context: nil, renderer: renderer)
      expect([result.replayed, log_steps]).to eq([false, %w[written called finished]])
      expect(runner.resume(registry: registry, id: key_row[:id], context: nil, renderer: renderer).replayed).to be(true)
    end

    it 'does not resume by id while the lease is live' do
      abandon_at('written')
      expect { runner.resume(registry: registry, id: key_row[:id], context: nil, renderer: renderer) }
        .to raise_error(idem::KeyInUseError)
      expect { runner.resume(registry: registry, id: -1, context: nil, renderer: renderer) }
        .to raise_error(ArgumentError)
    end

    it 'cannot commit once another runner has taken its lease, and its phase rolls back' do
      flow.before_atomic = lambda { |step, run|
        next unless step == 'called'

        # Another runner, on its own connection, takes the lease mid-phase.
        Thread.new { app_db[:idempotency_keys].where(id: run.key_id).update(lock_token: 'someone-else') }.join
      }
      expect { run_toy }.to raise_error(idem::LockLostError)
      expect(log_steps).to eq(%w[written])
      expect(key_row).to include(recovery_point: 'written', lock_token: 'someone-else')
    end
  end

  describe 'errors' do
    it 'stores a final error as the response, releases what the flow holds, and replays it' do
      flow.fail_in['called'] = ToyFlow::FinalError.new('no')
      first = run_toy
      expect([first.response.status, first.response.body]).to eq([400, '{"error":"no"}'])
      expect(key_row).to include(recovery_point: 'finished', response_code: 400, locked_at: nil)
      expect(flow.released).to eq([key_row[:id]])
      flow.fail_in.clear
      expect(run_toy.response).to eq(first.response)
      expect(log_steps).to eq(%w[written])
    end

    it 'gives the lease back on any other error and leaves the recovery point where it was' do
      flow.fail_in['written'] = ToyFlow::TransientError.new('db hiccup')
      expect { run_toy }.to raise_error(ToyFlow::TransientError)
      expect(key_row).to include(recovery_point: 'started', locked_at: nil, lock_token: nil)
    end

    it 'refuses a flow whose last phase does not answer' do
      silent = Class.new(ToyFlow::Flow) do
        def phases
          super.tap { |p| p[-1] = p[-1].class.new(from: 'called', to: 'finished', atomic: ->(_r, _d, _f) {}) }
        end
      end.new
      expect do
        runner.call(flow: silent, input: ToyFlow::Input.new(label: 'a'), request: toy_request, context: nil,
                    renderer: renderer)
      end.to raise_error(idem::Flow::DefinitionError, /must return a response/)
    end
  end

  describe 'the 24 hour window' do
    it 'forgets a finished key after 24 hours, so the key can be used again' do
      run_toy(label: 'a')
      clock.advance(described_class::KEY_TTL - 1)
      expect { run_toy(label: 'b') }.to raise_error(idem::KeyReusedError)
      clock.advance(1)
      expect(JSON.parse(run_toy(label: 'b').response.body)['label']).to eq('b')
      expect(app_db[:idempotency_keys].count).to eq(1)
    end

    it 'never forgets an unfinished key that way' do
      flow.fail_in['called'] = ToyFlow::TransientError.new('x')
      expect { run_toy }.to raise_error(ToyFlow::TransientError)
      clock.advance(described_class::KEY_TTL + 1)
      expect { run_toy(label: 'b') }.to raise_error(idem::KeyReusedError)
    end
  end

  describe 'requests without a key' do
    it 'still get a row, under a generated key nobody can replay' do
      run_toy(key: nil, request_id: 'req_one')
      run_toy(key: nil, request_id: 'req_two')
      rows = app_db[:idempotency_keys].order(:id).all
      expect(rows.map { |r| [r[:key], r[:client_supplied]] }).to eq([['auto_req_one', false], ['auto_req_two', false]])
      expect(flow.foreign_calls).to eq(%w[a a])
    end
  end

  describe 'serialization failures' do
    it 'retries the phase from the committed state, not from what the failed attempt left in memory' do
      failures = 0
      flow.before_atomic = lambda { |step, run|
        next unless step == 'written' && failures.zero?

        failures += 1
        run.state['leaked'] = true
        raise Sequel::SerializationFailure, 'could not serialize access'
      }
      expect(JSON.parse(run_toy.response.body)['state']).to eq('written_at' => 'a')
      expect(log_steps).to eq(%w[written called finished])
    end
  end

  it 'lets exactly one of many concurrent requests run, and every other one replays or is told to retry' do
    outcomes = Array.new(12) do
      Thread.new do
        run_toy.replayed ? :replayed : :ran
      rescue idem::KeyInUseError
        :in_use
      end
    end.map(&:value)
    expect(outcomes.count(:ran)).to eq(1)
    expect(outcomes.count(:ran) + outcomes.count(:replayed) + outcomes.count(:in_use)).to eq(12)
    expect(log_steps).to eq(%w[written called finished])
    expect(flow.foreign_calls).to eq(['a'])
  end
end
