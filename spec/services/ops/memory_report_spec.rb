require "rails_helper"

RSpec.describe Ops::MemoryReport do
  let(:logger) { instance_double(Logger, info: nil) }

  def logged
    messages = []
    allow(logger).to receive(:info) { |message| messages << message }
    described_class.call(logger: logger)
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

  it "omits resident memory rather than failing where /proc is unavailable" do
    allow(File).to receive(:read).with("/proc/self/status").and_raise(Errno::ENOENT)

    message = logged

    expect(message).not_to include("rss_mb")
    expect(message).to include("heap_live_slots=")
  end
end
