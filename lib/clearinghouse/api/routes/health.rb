# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Api
    module Routes
      # Liveness plus a database round trip, for docker compose and the demo script.
      # Unauthenticated and outside /v1, so it is never versioned.
      module Health
        extend T::Sig

        sig { params(app: T.class_of(App)).void }
        def self.registered(app)
          app.get '/healthz' do
            T.bind(self, App)
            begin
              ctx.db.fetch('SELECT 1 AS ok').single_value
              respond({ 'status' => 'ok', 'database' => 'ok' }, versioned: false)
            rescue Sequel::Error => e
              log_exception(e, ctx.request_id)
              respond({ 'status' => 'unavailable', 'database' => 'unreachable' }, status_code: 503, versioned: false)
            end
          end
        end
      end
    end
  end
end
