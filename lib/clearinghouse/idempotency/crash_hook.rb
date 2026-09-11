# typed: strict
# frozen_string_literal: true

module Clearinghouse
  module Idempotency
    # Called by the runner at every recovery point: just before the phase that
    # reaches it commits, and right after. In production it is DISARMED, which
    # does nothing. Fault injection supplies one that stops the process at a
    # chosen point, which is how experiment 2 crashes at every recovery point.
    #
    # Arming it from the environment:
    #
    #   CLEARINGHOUSE_ENV=test|experiment
    #   CLEARINGHOUSE_CRASH_AT=<flow>:<point>[:before_commit]
    #
    # e.g. `payment_intent.confirm:authorization_requested` kills the process
    # with `exit!` right after that phase commits, and
    # `...:authorization_requested:before_commit` kills it inside the transaction,
    # which rolls the phase back. The names are exactly Registry#crash_points'
    # `to_s`.
    #
    # Why it cannot fire in production: `from_env` returns the DISARMED constant
    # unless CLEARINGHOUSE_ENV is `test` or `experiment`, and Armed refuses to be
    # built otherwise, so a stray CLEARINGHOUSE_CRASH_AT in a production
    # environment does nothing. The environment is read once, when the
    # dependencies are built at boot; nothing can arm the hook in a running process.
    module CrashHook
      extend T::Sig
      extend T::Helpers

      interface!

      ENVIRONMENTS = %w[test experiment].freeze

      class NotAllowedError < Clearinghouse::Error; end

      sig { abstract.params(flow: String, point: String, moment: Symbol).void }
      def reached(flow, point, moment); end

      # The hook everything gets unless a test or experiment asks otherwise.
      class Disarmed
        extend T::Sig
        include CrashHook

        sig { override.params(flow: String, point: String, moment: Symbol).void }
        def reached(flow, point, moment); end
      end

      DISARMED = T.let(Disarmed.new.freeze, CrashHook)

      # Fires once, at one (flow, point, moment). The default action is `exit!`:
      # no ensure blocks, no at_exit handlers, no connection cleanup, as close to
      # a power cut as a process can do to itself. The open transaction, if any,
      # dies with the connection and Postgres rolls it back.
      class Armed
        extend T::Sig
        include CrashHook

        sig { returns(String) }
        attr_reader :target

        sig { params(target: String, env: T::Hash[String, String], action: T.proc.void).void }
        def initialize(target, env: ENV.to_h, action: -> { Process.exit!(CRASH_STATUS) })
          unless ENVIRONMENTS.include?(env['CLEARINGHOUSE_ENV'])
            raise NotAllowedError, 'the crash hook can only be armed when CLEARINGHOUSE_ENV is test or experiment'
          end

          @target = target
          @action = action
          @fired = T.let(false, T::Boolean)
        end

        sig { override.params(flow: String, point: String, moment: Symbol).void }
        def reached(flow, point, moment)
          return if @fired

          name = Registry::CrashPoint.new(flow: flow, point: point, moment: moment).to_s
          return unless name == @target

          @fired = true
          @action.call
        end
      end

      # The exit status a crashed process reports, so a harness can tell the
      # injected crash from a real failure.
      CRASH_STATUS = 86

      sig { params(env: T::Hash[String, String]).returns(CrashHook) }
      def self.from_env(env = ENV.to_h)
        target = env['CLEARINGHOUSE_CRASH_AT']
        return DISARMED if target.nil? || target.empty? || !ENVIRONMENTS.include?(env['CLEARINGHOUSE_ENV'])

        Armed.new(target, env: env)
      end
    end
  end
end
