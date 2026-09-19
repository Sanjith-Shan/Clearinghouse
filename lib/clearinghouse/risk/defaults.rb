# typed: true
# frozen_string_literal: true

module Clearinghouse
  # The process-wide pieces: one client (so one pool and one breaker) and where
  # review holds go.
  module Risk
    extend T::Sig

    @client = T.let(nil, T.nilable(Client))
    @client_mutex = T.let(Mutex.new, Thread::Mutex)
    @holds = T.let(nil, T.nilable(Holds))

    # The process's one client, built from RISKGATE_URL and RISKGATE_DEADLINE_MS on
    # first use. One per process because the pool and the breaker are only useful
    # shared.
    sig { returns(Client) }
    def self.client
      @client_mutex.synchronize { @client ||= Client.new }
    end

    sig { params(client: T.nilable(Client)).void }
    def self.client=(client)
      @client_mutex.synchronize { @client = client }
    end

    # Where review holds are opened by callers that do not pass one. The API
    # passes Dependencies#risk_holds instead. See Risk::Holds.
    sig { returns(Holds) }
    def self.holds
      @client_mutex.synchronize { @holds ||= Holds::Unwired.new }
    end

    sig { params(holds: T.nilable(Holds)).void }
    def self.holds=(holds)
      @client_mutex.synchronize { @holds = holds }
    end
  end
end
