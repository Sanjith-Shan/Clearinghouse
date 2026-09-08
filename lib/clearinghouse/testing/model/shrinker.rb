# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # Turns a failing sequence into a small one that fails the same check.
      #
      # 1. Cut everything after the failing step.
      # 2. Delta debugging (Zeller's ddmin) over the command list: try dropping
      #    chunks, halving the chunk size when nothing can go, down to single
      #    commands. Dropping a command that created an object leaves later commands
      #    naming something that does not exist; those just fail with
      #    resource_missing on both sides, so every candidate is still runnable.
      # 3. Shrink the numbers that are left (amounts, hours) toward small, round
      #    values, one at a time.
      #
      # A candidate counts only if it fails the *same* check (and, for an exception,
      # the same exception class), so shrinking cannot slide from one bug to another.
      class Shrinker
        extend T::Sig

        NUMERIC = %i[amount hours].freeze

        sig { returns(Integer) }
        attr_reader :attempts

        sig do
          params(runner: T.proc.params(commands: T::Array[Command]).returns(T.nilable(Failure)),
                 max_attempts: Integer).void
        end
        def initialize(runner, max_attempts: 5_000)
          @runner = runner
          @max_attempts = max_attempts
          @attempts = T.let(0, Integer)
        end

        sig { params(commands: T::Array[Command], failure: Failure).returns([T::Array[Command], Failure]) }
        def shrink(commands, failure)
          @target = T.let(signature(failure), T.nilable([Symbol, String]))
          @best = T.let(failure, T.nilable(Failure))
          current = T.must(commands[0..failure.index])
          loop do
            before = current
            current = ddmin(current)
            current = shrink_numbers(current)
            break if current == before || exhausted?
          end
          [current, T.must(@best)]
        end

        private

        sig { params(failure: Failure).returns([Symbol, String]) }
        def signature(failure)
          violation = failure.violation
          detail = violation.check == :exception ? violation.details.first.to_s.split(':').first.to_s : ''
          [violation.check, detail]
        end

        sig { returns(T::Boolean) }
        def exhausted?
          @attempts >= @max_attempts
        end

        # Runs a candidate. Keeps it as the best failure if it fails the same way.
        sig { params(candidate: T::Array[Command]).returns(T::Boolean) }
        def fails?(candidate)
          return false if exhausted?

          @attempts += 1
          failure = @runner.call(candidate)
          return false unless failure && signature(failure) == @target

          @best = failure
          true
        end

        sig { params(commands: T::Array[Command]).returns(T::Array[Command]) }
        def ddmin(commands)
          parts = 2
          while commands.length >= 2 && !exhausted?
            chunks = commands.each_slice((commands.length.to_f / parts).ceil).to_a
            reduced = T.let(nil, T.nilable(T::Array[Command]))
            chunks.each_index do |i|
              complement = T.let(chunks.reject.with_index { |_, j| j == i }.flatten(1), T::Array[Command])
              next unless fails?(complement)

              reduced = complement
              break
            end
            if reduced
              commands = reduced
              parts = [parts - 1, 2].max
            else
              break if parts >= commands.length

              parts = [parts * 2, commands.length].min
            end
          end
          commands
        end

        sig { params(commands: T::Array[Command]).returns(T::Array[Command]) }
        def shrink_numbers(commands)
          commands.each_index do |i|
            NUMERIC.each do |key|
              loop do
                value = T.must(commands[i]).args[key]
                break unless value.is_a?(Integer)

                smaller = candidates(value).find do |v|
                  trial = commands.dup
                  trial[i] = T.must(commands[i]).with_args(T.must(commands[i]).args.merge(key => v))
                  fails?(trial) && (commands = trial)
                end
                break unless smaller
              end
            end
          end
          commands
        end

        # Round numbers first, because a failure that needs 500 rather than 437 says
        # something about rounding; then halving and single steps down.
        sig { params(value: Integer).returns(T::Array[Integer]) }
        def candidates(value)
          round = [1, 10, 13, 24, 50, 100, 113, 200, 500, 1000, 1500].select { |v| v < value }
          (round + [value / 2, value - (value / 10), value - 1]).select(&:positive?).uniq.reject { |v| v >= value }
        end
      end
    end
  end
end
