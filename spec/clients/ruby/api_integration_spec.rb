# typed: false
# frozen_string_literal: true

require 'puma'
require_relative 'client_helper'

# The client against the real API on Puma, over a real socket: auth, JSON bodies,
# version headers and error mapping as the server actually sends them. Payment
# endpoints are exercised against the scripted server until they land.
RSpec.describe ClearinghouseClient::Client, :db do
  let(:clock) { Clearinghouse::Clock::Test.new(start: Time.utc(2026, 9, 1, 12)) }
  let(:deps) do
    Clearinghouse::Api::Dependencies.new(db: app_db, clock: clock, log: nil, admin_token: 'admin_sdk_token')
  end
  let(:sleeper) { RecordingSleeper.new }
  let!(:server) do
    Puma::Server.new(Clearinghouse::Api.rack_app(deps), nil, min_threads: 1, max_threads: 4,
                                                             log_writer: Puma::LogWriter.null).tap do |s|
      s.add_tcp_listener('127.0.0.1', 0)
      s.run
    end
  end
  let(:base_url) { "http://127.0.0.1:#{server.connected_ports.first}" }

  after { server.stop(true) }

  def client(api_key, **options)
    described_class.new(api_key: api_key, base_url: base_url, sleeper: sleeper.to_proc, **options)
  end

  def create_merchant(**params)
    client('admin_sdk_token').request(:post, '/v1/merchants', params: { name: 'Rocket Rides', **params })
  end

  it 'creates a merchant with a JSON body, then authenticates as it' do
    created = create_merchant(api_version: '2026-03-01')
    expect(created.status).to eq(201)
    expect(created.request_id).to match(/\Areq_/)
    merchant = created.data

    account = client(merchant.fetch('secret_key')).request(:get, '/v1/account')
    expect(account.data.fetch('id')).to eq(merchant.fetch('id'))
    expect(account.headers['clearinghouse-version']).to eq('2026-03-01')
    expect(account.request_id).to match(/\Areq_/)
    expect(account.request_id).not_to eq(created.request_id)
  end

  it "sends Clearinghouse-Version over the merchant's pin, per client and per call" do
    key = create_merchant(api_version: '2026-01-01').data.fetch('secret_key')
    pinned = client(key, api_version: '2026-06-01')
    expect(pinned.request(:get, '/v1/account').headers['clearinghouse-version']).to eq('2026-06-01')
    expect(pinned.request(:get, '/v1/account', api_version: '2026-09-01').headers['clearinghouse-version'])
      .to eq('2026-09-01')
  end

  it 'serves account.retrieve through the resource helper' do
    merchant = create_merchant.data
    expect(client(merchant.fetch('secret_key')).account.retrieve).to include('id' => merchant.fetch('id'))
  end

  it 'maps a wrong key to AuthenticationError without retrying' do
    expect { client('sk_test_000000000000000000000000').request(:get, '/v1/account') }
      .to raise_error(ClearinghouseClient::AuthenticationError) { |e|
        expect([e.http_status, e.code]).to eq([401, 'api_key_invalid'])
        expect(e.request_id).to match(/\Areq_/)
        expect(e.http_headers['clearinghouse-should-retry']).to eq('false')
      }
    expect(sleeper.calls).to be_empty
  end

  it 'maps an unknown version to InvalidRequestError naming the code' do
    key = create_merchant.data.fetch('secret_key')
    expect { client(key, api_version: '1999-01-01').request(:get, '/v1/account') }
      .to raise_error(ClearinghouseClient::InvalidRequestError) { |e|
        expect([e.http_status, e.code]).to eq([400, 'api_version_invalid'])
      }
  end

  it 'maps a bad parameter to InvalidRequestError with its param' do
    expect { create_merchant(name: '') }.to raise_error(ClearinghouseClient::InvalidRequestError) { |e|
      expect(e.param).to eq('name')
    }
    expect(sleeper.calls).to be_empty
  end
end
