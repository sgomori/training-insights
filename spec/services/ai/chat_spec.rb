require "rails_helper"

RSpec.describe Ai::Chat do
  let(:client) { instance_double(Ai::Client, answer: "He has been running well.") }
  let(:today) { Date.new(2026, 9, 5) }

  def ask(question = "how is training going?", runner_name: "Steve Gomori")
    described_class.call(question: question, runner_name: runner_name, today: today, client: client)
  end

  it "returns the answer" do
    expect(ask).to eq("He has been running well.")
  end

  it "asks under the chat prompt" do
    ask

    expect(client).to have_received(:answer).with(hash_including(system: Ai::ChatPrompt.for("Steve Gomori", today: today)))
  end

  it "dates the prompt from the day it was given" do
    ask

    expect(client).to have_received(:answer).with(hash_including(system: a_string_including("Today is Saturday 5 September 2026")))
  end

  it "passes the question through unchanged" do
    ask("what did his last hard session look like?")

    expect(client).to have_received(:answer).with(hash_including(question: "what did his last hard session look like?"))
  end

  it "uses the configured chat model" do
    with_env("ANTHROPIC_CHAT_MODEL" => "claude-sonnet-5") { ask }

    expect(client).to have_received(:answer).with(hash_including(model: "claude-sonnet-5"))
  end
end
