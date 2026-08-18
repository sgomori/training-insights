require "rails_helper"

# The queue configuration fails silently in both directions, which is why it is
# worth a test at all. A worker whose queue list does not match a job's queue
# boots, registers, heartbeats and polls exactly like a healthy one — it simply
# claims nothing, and no exception is ever raised. The jobs sit in
# solid_queue_ready_executions with failed=0 until somebody looks.
RSpec.describe "the Solid Queue worker configuration" do
  subject(:pools) { SolidQueue::Configuration.new.send(:workers_options) }

  # Every queue this application actually enqueues onto. solid_queue_recurring
  # is Solid Queue's own: config/recurring.yml uses `command:` entries, which
  # arrive as SolidQueue::RecurringJob rather than on default.
  QUEUES_IN_USE = {
    "default" => "RegenerateContentJob and anything unqualified",
    "chat" => "ChatJob",
    "solid_queue_recurring" => "the entries in config/recurring.yml"
  }.freeze

  def queues_for(pool) = Array(pool[:queues]).map(&:to_s)

  # Solid Queue never splits on commas: Worker#initialize takes
  # Array(options[:queues]) as-is, so "default,chat" is one queue name of that
  # literal text and matches nothing. Worker#metadata then reports
  # queues.join(","), so a broken pool and a correct one print identically in
  # solid_queue_processes — there is no way to catch this from the outside.
  it "names queues as a YAML list rather than a comma-separated string" do
    offenders = pools.flat_map { |pool| queues_for(pool) }.select { |name| name.include?(",") }

    expect(offenders).to be_empty,
      "these are single queue names containing a comma, and will match no job: #{offenders.inspect}"
  end

  QUEUES_IN_USE.each do |queue, carries|
    it "polls #{queue}, which carries #{carries}" do
      expect(pools.flat_map { |pool| queues_for(pool) }).to include(queue)
    end
  end

  # The pools are named rather than "*" so a chat turn a visitor is waiting on
  # cannot sit behind a content regeneration. Overlap would put both pools on the
  # same jobs and give that up.
  it "keeps the pools disjoint, so the split does what it exists to do" do
    all = pools.flat_map { |pool| queues_for(pool) }

    expect(all).to eq(all.uniq)
    expect(all).not_to include("*")
  end

  it "matches the queues the jobs actually declare" do
    expect(ChatJob.new.queue_name).to eq("chat")
    expect(RegenerateContentJob.new.queue_name).to eq("default")
  end
end
