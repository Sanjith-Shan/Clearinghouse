# typed: true
# frozen_string_literal: true

module Clearinghouse
  module Testing
    module Model
      # Renders a failing sequence as a Ruby script that replays it step by step,
      # printing each outcome, and stops with the same failure.
      module Script
        extend T::Sig

        sig do
          params(commands: T::Array[Command], failure: Failure, sut: String, plant: T.nilable(String),
                 seed: Integer).returns(String)
        end
        def self.render(commands, failure, sut:, plant:, seed:)
          header = failure.to_s.lines.map { |line| "# #{line.chomp}".rstrip }
          <<~RUBY
            # Reproduces a model-based test failure (sequence seed #{seed}), shrunk to
            # #{commands.length} steps.
            #
            #{header.join("\n")}
            #
            # Run from the repository root:
            #   CLEARINGHOUSE_DB=clearinghouse_test bundle exec ruby path/to/this_file.rb
            require File.expand_path('lib/clearinghouse/testing/model', Dir.pwd)

            Clearinghouse::Testing::Model::Harness.replay(sut: #{sut.to_sym.inspect}, plant: #{plant&.to_sym.inspect}) do |h|
            #{commands.map { |c| "  #{c.to_ruby}" }.join("\n")}
            end
          RUBY
        end
      end

      # The object a reproduction script drives: one method per operation, each
      # running the step on the model and the system under test, printing the
      # outcome, and raising Harness::Failed with the check's details on a failure.
      class Harness
        extend T::Sig

        class Failed < Clearinghouse::Error; end

        sig do
          params(sut: Symbol, plant: T.nilable(Symbol), out: T.any(IO, StringIO),
                 blk: T.proc.params(h: Harness).void).void
        end
        def self.replay(sut:, plant: nil, out: $stdout, &blk)
          harness = new(Model.build_sut(sut.to_s, plant: plant&.to_s), out: out)
          blk.call(harness)
          out.puts("all #{harness.session.steps} steps passed every check")
        end

        sig { returns(Session) }
        attr_reader :session

        sig { params(sut: Sut, out: T.any(IO, StringIO)).void }
        def initialize(sut, out: $stdout)
          @session = T.let(Session.new(sut), Session)
          @out = out
        end

        Sut::OPERATIONS.each do |op|
          define_method(op) do |**args|
            command = Command.new(op: op, args: args)
            step = @session.step(command)
            @out.puts("#{@session.steps}. #{command.to_ruby.delete_prefix('h.')}")
            @out.puts("     model:  #{step.expected}\n     system: #{step.actual || 'raised'}")
            violation = step.violation
            next step.actual unless violation

            raise Failed, "check #{violation.check} failed:\n#{violation.details.map { |d| "  #{d}" }.join("\n")}"
          end
        end
      end
    end
  end
end
