# typed: false
# frozen_string_literal: true

# The real monotonic clock, keeping every reading, so a spec can check the times the
# code under test acted on instead of the wall time around it.
class RecordingClock
  include Clearinghouse::Risk::Monotonic

  attr_reader :readings

  def initialize
    @real = Clearinghouse::Risk::Monotonic::Real.new
    @readings = []
    @mutex = Mutex.new
  end

  def now
    @real.now.tap { |t| @mutex.synchronize { @readings << t } }
  end
end
