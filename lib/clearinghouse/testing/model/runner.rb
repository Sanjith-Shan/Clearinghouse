# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # Generates and runs random sequences against a system under test, and on the
      # first failure shrinks it and renders a script that reproduces it.
      class Runner
        extend T::Sig

        # Counts for the report.
        class Stats < T::Struct
          prop :sequences, Integer, default: 0
          prop :operations, Integer, default: 0
          prop :by_operation, T::Hash[String, Integer], default: {}
          # "op ok" or "op error_code" => count, to show the illegal paths were reached
          prop :by_outcome, T::Hash[String, Integer], default: {}
          # money events (Ledger::Flows builders) the sequences exercised
          prop :by_event, T::Hash[String, Integer], default: {}
        end

        # The first failure found, before and after shrinking.
        class FoundFailure < T::Struct
          const :sequence_seed, Integer
          const :original, T::Array[Command]
          const :original_failure, Failure
          const :shrunk, T::Array[Command]
          const :shrunk_failure, Failure
          const :shrink_attempts, Integer
          const :script, String
        end

        # What a run found.
        class Report < T::Struct
          const :stats, Stats
          const :failure, T.nilable(FoundFailure)
        end

        sig do
          params(sut_factory: T.proc.returns(Sut), sut_name: String, seed: Integer, sequences: Integer,
                 max_length: Integer, plant: T.nilable(String), log: T.nilable(T.any(IO, StringIO))).void
        end
        def initialize(sut_factory:, sut_name:, seed:, sequences:, max_length:, plant: nil, log: nil)
          @sut_factory = sut_factory
          @sut_name = sut_name
          @seed = seed
          @sequences = sequences
          @max_length = max_length
          @plant = plant
          @log = log
          @sut = T.let(nil, T.nilable(Sut))
        end

        sig { returns(Report) }
        def run
          stats = Stats.new
          @sequences.times do |i|
            sequence_seed = (@seed * 1_000_003) + i
            commands, failure = run_generated(sequence_seed, stats)
            stats.sequences += 1
            return Report.new(stats: stats, failure: shrink(sequence_seed, commands, failure)) if failure

            @log&.puts("sequence #{i + 1}/#{@sequences}: #{commands.length} operations ok") if ((i + 1) % 10).zero?
          end
          Report.new(stats: stats)
        end

        private

        sig { returns(Sut) }
        def sut
          @sut ||= @sut_factory.call
        end

        sig { params(sequence_seed: Integer, stats: Stats).returns([T::Array[Command], T.nilable(Failure)]) }
        def run_generated(sequence_seed, stats)
          rng = Random.new(sequence_seed)
          generator = Generator.new(rng, exclude_operations: sut.unsupported_operations,
                                         exclude_cards: sut.unsupported_payment_methods)
          session = Session.new(sut)
          length = rng.rand(((@max_length + 1) / 2)..@max_length)
          commands = []
          length.times do |index|
            command = generator.next_command(session.model)
            commands << command
            step = session.step(command)
            record(stats, command, step)
            violation = step.violation
            return [commands, Failure.new(index: index, command: command, violation: violation)] if violation
          end
          [commands, nil]
        end

        sig { params(stats: Stats, command: Command, step: Session::Step).void }
        def record(stats, command, step)
          stats.operations += 1
          op = command.op.to_s
          stats.by_operation[op] = stats.by_operation.fetch(op, 0) + 1
          key = "#{op} #{step.expected.ok ? 'ok' : step.expected.code}"
          stats.by_outcome[key] = stats.by_outcome.fetch(key, 0) + 1
          step.events.each { |e| stats.by_event[e.kind.to_s] = stats.by_event.fetch(e.kind.to_s, 0) + 1 }
        end

        sig do
          params(sequence_seed: Integer, commands: T::Array[Command], failure: Failure).returns(FoundFailure)
        end
        def shrink(sequence_seed, commands, failure)
          @log&.puts("FAILED at #{failure}\nshrinking #{commands.length} operations...")
          shrinker = Shrinker.new(->(candidate) { Session.first_failure(sut, candidate) })
          shrunk, shrunk_failure = shrinker.shrink(commands, failure)
          FoundFailure.new(sequence_seed: sequence_seed, original: commands, original_failure: failure,
                           shrunk: shrunk, shrunk_failure: shrunk_failure, shrink_attempts: shrinker.attempts,
                           script: Script.render(shrunk, shrunk_failure, sut: @sut_name, plant: @plant,
                                                                         seed: sequence_seed))
        end
      end
    end
  end
end
