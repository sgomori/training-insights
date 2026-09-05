require "rails_helper"

RSpec.describe Ai::Content do
  let(:client) { instance_double(Ai::Client, answer: "Volume has been climbing since May.") }
  let(:today) { Date.new(2026, 9, 5) }

  def generate(runner_name: "Steve Gomori")
    described_class.call(runner_name: runner_name, today: today, client: client)
  end

  it "returns the summary" do
    expect(generate).to eq("Volume has been climbing since May.")
  end

  it "writes under the content prompt" do
    generate

    expect(client).to have_received(:answer).with(hash_including(system: Ai::ContentPrompt.for("Steve Gomori", today: today)))
  end

  # "The last few weeks" has to count back from somewhere, and the tools'
  # own as_of only arrives after the model has decided what to ask them.
  it "dates the prompt from the day it was given" do
    generate

    expect(client).to have_received(:answer).with(hash_including(system: a_string_including("Today is Saturday 5 September 2026")))
  end

  # The activity that triggered a regeneration is a signal and a cache key, never
  # an input: this asks the model to gather the training through the tools,
  # exactly as chat does.
  it "takes no training data, only a request to go and find it" do
    generate

    expect(client).to have_received(:answer).with(hash_including(question: Ai::ContentPrompt.request))
  end

  # Content regenerates on every new activity, so it is the cost-sensitive path
  # and the one most likely to be moved to a cheaper model.
  it "uses the configured content model" do
    with_env("ANTHROPIC_CONTENT_MODEL" => "claude-sonnet-5") { generate }

    expect(client).to have_received(:answer).with(hash_including(model: "claude-sonnet-5"))
  end
end
