# typed: false
# frozen_string_literal: true

require 'open3'

RSpec.describe 'bin/completer', :db do
  include_context 'with the api app'
  include_context 'with a merchant'
  include_context 'with the acquirer'

  it 'finishes an abandoned confirm in its own process and says so on one JSON line' do
    id = create_intent(payment_method: 'pm_card_timeout')['id']
    confirm(id)
    # The key was last run at the test clock's time, in the past on the wall clock
    # the completer process reads, so no grace is needed.
    env = { 'CLEARINGHOUSE_ENV' => 'test', 'CLEARINGHOUSE_DB' => ENV.fetch('CLEARINGHOUSE_DB', 'clearinghouse_test'),
            'CLEARINGHOUSE_ACQUIRER_URL' => AcquirerSpec.server.url, 'RISKGATE_URL' => 'http://127.0.0.1:9' }
    out, status = Open3.capture2(env, File.expand_path('../../../bin/completer', __dir__), '--once', '--grace', '0')
    expect(status.success?).to be(true)
    line = JSON.parse(out.lines.last)
    expect(line.keys).to include('completed', 'busy', 'failed', 'expired', 'reaped', 'stuck')
    expect(line['completed'].length).to eq(1)
    expect(intent_row(id)[:status]).to eq('succeeded')
  end
end
