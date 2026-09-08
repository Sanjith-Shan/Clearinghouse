# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # A step that broke a check: which step, what it was, and what the check saw.
      class Failure < T::Struct
        extend T::Sig

        const :index, Integer
        const :command, Command
        const :violation, Checks::Violation

        sig { returns(String) }
        def to_s
          "step #{index + 1} (#{command.to_ruby}) failed check #{violation.check}:\n" +
            violation.details.first(20).map { |d| "  #{d}" }.join("\n")
        end
      end

      # Runs commands against the reference model and a system under test side by
      # side, checking everything after every step.
      class Session
        extend T::Sig

        # What one step produced.
        class Step < T::Struct
          const :expected, Outcome
          const :actual, T.nilable(Outcome)
          const :violation, T.nilable(Checks::Violation)
          # The money the model expected this step to move.
          const :events, T::Array[Event], default: []
        end

        sig { returns(ReferenceModel) }
        attr_reader :model

        sig { returns(Integer) }
        attr_reader :steps

        sig { params(sut: Sut).void }
        def initialize(sut)
          @sut = sut
          @model = T.let(ReferenceModel.new, ReferenceModel)
          @steps = T.let(0, Integer)
          sut.reset!
        end

        sig { params(command: Command).returns(Step) }
        def step(command)
          @steps += 1
          expected = @model.apply(command)
          events = @model.drain_events
          begin
            actual = @sut.apply(command)
            violation = Checks.first_violation(model: @model, expected: expected, actual: actual,
                                               model_snapshot: @model.snapshot, sut_snapshot: @sut.snapshot)
          rescue StandardError => e
            violation = Checks::Violation.new(check: :exception, details: exception_details(e))
          end
          Step.new(expected: expected, actual: actual, violation: violation, events: events)
        end

        # Runs commands until one breaks a check.
        sig { params(sut: Sut, commands: T::Array[Command]).returns(T.nilable(Failure)) }
        def self.first_failure(sut, commands)
          session = new(sut)
          commands.each_with_index do |command, index|
            violation = session.step(command).violation
            return Failure.new(index: index, command: command, violation: violation) if violation
          end
          nil
        end

        private

        # The first line names the exception class, which the shrinker matches on.
        sig { params(error: StandardError).returns(T::Array[String]) }
        def exception_details(error)
          ["#{error.class}: #{error.message.lines.first&.chomp}"] +
            (error.backtrace || []).grep_v(/gems|rspec/).first(6)
        end
      end
    end
  end
end
