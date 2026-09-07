require "rails_helper"

RSpec.describe Ops::MemoryReport do
  subject(:report) { described_class.new(logger: logger) }

  let(:logger) { instance_double(Logger, info: nil) }

  def logged
    messages = []
    allow(logger).to receive(:info) { |message| messages << message }
    report.call
    messages.sole
  end

  it "reports resident memory in megabytes" do
    expect(logged).to match(/\brss_mb=\d+(\.\d+)?\b/)
  end

  it "reports the garbage collector statistics worth trending" do
    message = logged

    described_class::STATS.each do |stat|
      expect(message).to match(/\b#{stat}=\d+\b/)
    end
  end

  # /up passes with the job threads dead. The heartbeat age is the one signal
  # that a worker has stopped, so it rides on the line already being watched.
  describe "the queue's pulse" do
    # Stubbed at the report's own seam: the test database carries no queue
    # tables, and a stub on the Solid Queue class would load their schema.
    def workers_registered(*heartbeats)
      allow(report).to receive(:worker_heartbeats).and_return(heartbeats)
    end

    # Two pools register two workers. The question is whether any of them is
    # stale, so the newest heartbeat would hide a dead chat pool behind a live
    # default one.
    it "reports the registered workers and the age of the oldest heartbeat" do
      workers_registered(40.seconds.ago, 25.minutes.ago)

      message = logged
      expect(message).to match(/\bworkers=2\b/)
      expect(message).to match(/\bworker_heartbeat_age_s=(1499|1500|1501)\b/)
    end

    # The field stays on the line, so the shape does not change in the one case
    # a reader grepping for it cares about most.
    it "reports no workers with a greppable age of none" do
      workers_registered

      message = logged
      expect(message).to match(/\bworkers=0\b/)
      expect(message).to match(/\bworker_heartbeat_age_s=none\b/)
    end

    it "never reports a negative age from a clock running ahead" do
      workers_registered(10.seconds.from_now)

      expect(logged).to match(/\bworker_heartbeat_age_s=0\b/)
    end

    it "omits the queue rather than failing where its tables cannot be reached" do
      allow(report).to receive(:worker_heartbeats).and_raise(ActiveRecord::StatementInvalid, "no such table")

      message = logged
      expect(message).not_to include("workers")
      expect(message).to include("heap_live_slots=")
    end
  end

  it "omits resident memory rather than failing where /proc is unavailable" do
    allow(File).to receive(:read).with("/proc/self/status").and_raise(Errno::ENOENT)

    message = logged

    expect(message).not_to include("rss_mb")
    expect(message).to include("heap_live_slots=")
  end
end
